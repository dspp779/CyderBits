#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define FRAME_COUNT 256
#define CODE_SIZE 27
#define RETURN_OFFSET 22

typedef ULONG (WINAPI *rtl_walk_frame_chain_t)(void **, ULONG, ULONG);
typedef BOOLEAN (WINAPI *rtl_add_function_table_t)(PRUNTIME_FUNCTION, DWORD, DWORD64);
typedef BOOLEAN (WINAPI *rtl_delete_function_table_t)(PRUNTIME_FUNCTION);
typedef void (WINAPI *generated_function_t)(void);

static rtl_walk_frame_chain_t rtl_walk_frame_chain;
static void *frames[FRAME_COUNT];
static ULONG frame_count;

static void *const sentinel = (void *)(uintptr_t)0xccccccccccccccccULL;

__attribute__((noinline)) static void WINAPI capture_frames(void)
{
    frame_count = rtl_walk_frame_chain(frames, FRAME_COUNT, 0);
}

static int verify_result(const char *scenario, const BYTE *code)
{
    if (frame_count != 2)
    {
        fprintf(stderr, "FAIL %s: expected 2 frames, got %lu\n",
                scenario, (unsigned long)frame_count);
        return 0;
    }
    if (frames[1] != code + RETURN_OFFSET)
    {
        fprintf(stderr, "FAIL %s: expected second frame %p, got %p\n",
                scenario, code + RETURN_OFFSET, frames[1]);
        return 0;
    }
    if (frames[2] != sentinel)
    {
        fprintf(stderr, "FAIL %s: frame walk wrote past boundary: %p\n",
                scenario, frames[2]);
        return 0;
    }
    printf("PASS %s\n", scenario);
    return 1;
}

static int run_frame_walk(const char *scenario, BYTE *code)
{
    unsigned int i;

    for (i = 0; i < FRAME_COUNT; ++i) frames[i] = sentinel;
    frame_count = 0;
    ((generated_function_t)code)();
    return verify_result(scenario, code);
}

int main(void)
{
    static const BYTE generated_code[CODE_SIZE] =
    {
        0xb8, 0xef, 0xbe, 0xad, 0xde,               /* mov $0xdeadbeef,%eax */
        0x50, 0x50, 0x50, 0x50, 0x50,               /* shadow space + alignment */
        0x48, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0,         /* movabs capture_frames,%rax */
        0xff, 0xd0,                                 /* callq *%rax */
        0x48, 0x83, 0xc4, 0x28,                     /* addq $0x28,%rsp */
        0xc3,                                       /* ret */
    };
    rtl_add_function_table_t rtl_add_function_table;
    rtl_delete_function_table_t rtl_delete_function_table;
    RUNTIME_FUNCTION runtime_function;
    DWORD old_protection;
    HMODULE ntdll;
    SYSTEM_INFO system_info;
    SIZE_T allocation_size;
    BYTE *code;
    BYTE *metadata;
    int success = 0;

    ntdll = GetModuleHandleA("ntdll.dll");
    rtl_walk_frame_chain = (rtl_walk_frame_chain_t)GetProcAddress(ntdll, "RtlWalkFrameChain");
    rtl_add_function_table = (rtl_add_function_table_t)GetProcAddress(ntdll, "RtlAddFunctionTable");
    rtl_delete_function_table = (rtl_delete_function_table_t)GetProcAddress(ntdll, "RtlDeleteFunctionTable");
    if (!rtl_walk_frame_chain || !rtl_add_function_table || !rtl_delete_function_table)
    {
        fprintf(stderr, "FAIL unable to resolve required NTDLL exports\n");
        return 1;
    }

    GetSystemInfo(&system_info);
    allocation_size = (SIZE_T)system_info.dwPageSize * 2;
    code = VirtualAlloc(NULL, allocation_size, MEM_COMMIT | MEM_RESERVE,
                        PAGE_EXECUTE_READWRITE);
    if (!code)
    {
        fprintf(stderr, "FAIL VirtualAlloc: %lu\n", (unsigned long)GetLastError());
        return 1;
    }
    metadata = code + system_info.dwPageSize;

    memcpy(code, generated_code, sizeof(generated_code));
    *(void **)(code + 12) = capture_frames;
    FlushInstructionCache(GetCurrentProcess(), code, sizeof(generated_code));

    if (!run_frame_walk("missing runtime function stops safely", code)) goto done;

    runtime_function.BeginAddress = 0;
    runtime_function.EndAddress = CODE_SIZE;
    runtime_function.UnwindData = system_info.dwPageSize;
    if (!rtl_add_function_table(&runtime_function, 1, (DWORD64)(uintptr_t)code))
    {
        fprintf(stderr, "FAIL RtlAddFunctionTable\n");
        goto done;
    }
    if (!VirtualProtect(metadata, system_info.dwPageSize, PAGE_NOACCESS, &old_protection))
    {
        fprintf(stderr, "FAIL VirtualProtect(PAGE_NOACCESS): %lu\n",
                (unsigned long)GetLastError());
        rtl_delete_function_table(&runtime_function);
        goto done;
    }

    if (!run_frame_walk("unreadable unwind metadata stops safely", code))
    {
        VirtualProtect(metadata, system_info.dwPageSize, old_protection, &old_protection);
        rtl_delete_function_table(&runtime_function);
        goto done;
    }

    VirtualProtect(metadata, system_info.dwPageSize, old_protection, &old_protection);
    if (!rtl_delete_function_table(&runtime_function))
    {
        fprintf(stderr, "FAIL RtlDeleteFunctionTable\n");
        goto done;
    }

    success = 1;
    puts("PASS ntdll frame-walk guard regression");

done:
    VirtualFree(code, 0, MEM_RELEASE);
    return success ? 0 : 1;
}
