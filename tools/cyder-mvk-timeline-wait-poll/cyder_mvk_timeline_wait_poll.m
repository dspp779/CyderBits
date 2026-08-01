/*
 * Cyder MoltenVK shim: host vkWaitSemaphores* polls timeline counters.
 *
 * Avoids -[MTLSharedEvent notifyListener:atValue:block:], which retains a Mach
 * receive right until the waited value is reached. Finite-timeout waits from
 * DXVK that expire first leak those rights. Matches
 * patches/cyder-moltenvk-timeline-wait-poll.patch when Xcode is unavailable.
 *
 * Layout: libMoltenVK.dylib (this shim) re-exports libMoltenVK.real.dylib.
 */
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

/* File-scope so `strings` / install detection always see the marker. */
static const char cyder_mvk_wait_poll_marker[] __attribute__((used)) =
    "cyder-moltenvk-timeline-wait-poll";

typedef int32_t CyderVkResult;
typedef uint32_t CyderVkFlags;
typedef uint32_t CyderVkStructureType;
typedef void *CyderVkDevice;
typedef void *CyderVkInstance;
typedef void *CyderVkSemaphore;
typedef void (*CyderPFN_vkVoidFunction)(void);

enum {
    CYDER_VK_SUCCESS = 0,
    CYDER_VK_TIMEOUT = 2,
    CYDER_VK_ERROR_INITIALIZATION_FAILED = -3,
    CYDER_VK_SEMAPHORE_WAIT_ANY_BIT = 0x00000001u,
};

/* Matches VkSemaphoreWaitInfo on LP64. */
typedef struct CyderVkSemaphoreWaitInfo {
    CyderVkStructureType sType;
    const void *pNext;
    CyderVkFlags flags;
    uint32_t semaphoreCount;
    const CyderVkSemaphore *pSemaphores;
    const uint64_t *pValues;
} CyderVkSemaphoreWaitInfo;

static CyderVkResult (*real_vkGetSemaphoreCounterValue)(CyderVkDevice, CyderVkSemaphore, uint64_t *) = NULL;
static CyderVkResult (*real_vkGetSemaphoreCounterValueKHR)(CyderVkDevice, CyderVkSemaphore, uint64_t *) = NULL;
static CyderVkResult (*real_vkWaitSemaphores)(CyderVkDevice, const CyderVkSemaphoreWaitInfo *, uint64_t) = NULL;
static CyderVkResult (*real_vkWaitSemaphoresKHR)(CyderVkDevice, const CyderVkSemaphoreWaitInfo *,
                                                 uint64_t) = NULL;
static CyderPFN_vkVoidFunction (*real_vkGetDeviceProcAddr)(CyderVkDevice, const char *) = NULL;
static CyderPFN_vkVoidFunction (*real_vkGetInstanceProcAddr)(CyderVkInstance, const char *) = NULL;
static CyderPFN_vkVoidFunction (*real_vk_icdGetInstanceProcAddr)(CyderVkInstance, const char *) = NULL;

static CyderVkResult cyder_get_counter(CyderVkDevice device, CyderVkSemaphore sem, uint64_t *value) {
    if (real_vkGetSemaphoreCounterValue) {
        return real_vkGetSemaphoreCounterValue(device, sem, value);
    }
    if (real_vkGetSemaphoreCounterValueKHR) {
        return real_vkGetSemaphoreCounterValueKHR(device, sem, value);
    }
    return CYDER_VK_ERROR_INITIALIZATION_FAILED;
}

static int cyder_is_reached(CyderVkDevice device, const CyderVkSemaphoreWaitInfo *info, uint32_t i) {
    uint64_t value = 0;
    CyderVkResult r = cyder_get_counter(device, info->pSemaphores[i], &value);
    if (r != CYDER_VK_SUCCESS) {
        return 0;
    }
    return value >= info->pValues[i];
}

static int cyder_is_complete(CyderVkDevice device, const CyderVkSemaphoreWaitInfo *info) {
    if (!info || info->semaphoreCount == 0) {
        return 1;
    }
    int wait_any = (info->flags & CYDER_VK_SEMAPHORE_WAIT_ANY_BIT) != 0;
    if (wait_any) {
        for (uint32_t i = 0; i < info->semaphoreCount; i++) {
            if (cyder_is_reached(device, info, i)) {
                return 1;
            }
        }
        return 0;
    }
    for (uint32_t i = 0; i < info->semaphoreCount; i++) {
        if (!cyder_is_reached(device, info, i)) {
            return 0;
        }
    }
    return 1;
}

static uint64_t cyder_now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static void cyder_sleep_ns(uint64_t ns) {
    struct timespec ts;
    ts.tv_sec = (time_t)(ns / 1000000000ull);
    ts.tv_nsec = (long)(ns % 1000000000ull);
    nanosleep(&ts, NULL);
}

static CyderVkResult cyder_wait_semaphores_poll(CyderVkDevice device, const CyderVkSemaphoreWaitInfo *info,
                                                uint64_t timeout) {
    if (!info) {
        return CYDER_VK_ERROR_INITIALIZATION_FAILED;
    }
    if (!real_vkGetSemaphoreCounterValue && !real_vkGetSemaphoreCounterValueKHR) {
        /* Fallback: better a port leak than a hard fail if resolve failed. */
        if (real_vkWaitSemaphoresKHR) {
            return real_vkWaitSemaphoresKHR(device, info, timeout);
        }
        if (real_vkWaitSemaphores) {
            return real_vkWaitSemaphores(device, info, timeout);
        }
        return CYDER_VK_ERROR_INITIALIZATION_FAILED;
    }

    if (cyder_is_complete(device, info)) {
        return CYDER_VK_SUCCESS;
    }
    if (timeout == 0) {
        return CYDER_VK_TIMEOUT;
    }

    const uint64_t start = cyder_now_ns();
    const int timed = (timeout != UINT64_MAX);
    static const uint64_t kPollSliceNs = 100000ull; /* 100us */

    for (;;) {
        if (cyder_is_complete(device, info)) {
            return CYDER_VK_SUCCESS;
        }
        if (timed) {
            uint64_t elapsed = cyder_now_ns() - start;
            if (elapsed >= timeout) {
                return CYDER_VK_TIMEOUT;
            }
            uint64_t remaining = timeout - elapsed;
            cyder_sleep_ns(remaining < kPollSliceNs ? remaining : kPollSliceNs);
        } else {
            cyder_sleep_ns(kPollSliceNs);
        }
    }
}

__attribute__((visibility("default"))) CyderVkResult
vkWaitSemaphores(CyderVkDevice device, const CyderVkSemaphoreWaitInfo *info, uint64_t timeout);
__attribute__((visibility("default"))) CyderVkResult
vkWaitSemaphoresKHR(CyderVkDevice device, const CyderVkSemaphoreWaitInfo *info, uint64_t timeout);
__attribute__((visibility("default"))) CyderPFN_vkVoidFunction
vkGetDeviceProcAddr(CyderVkDevice device, const char *name);
__attribute__((visibility("default"))) CyderPFN_vkVoidFunction
vkGetInstanceProcAddr(CyderVkInstance instance, const char *name);
__attribute__((visibility("default"))) CyderPFN_vkVoidFunction
vk_icdGetInstanceProcAddr(CyderVkInstance instance, const char *name);

__attribute__((visibility("default"))) CyderVkResult
vkWaitSemaphores(CyderVkDevice device, const CyderVkSemaphoreWaitInfo *info, uint64_t timeout) {
    return cyder_wait_semaphores_poll(device, info, timeout);
}

__attribute__((visibility("default"))) CyderVkResult
vkWaitSemaphoresKHR(CyderVkDevice device, const CyderVkSemaphoreWaitInfo *info, uint64_t timeout) {
    return cyder_wait_semaphores_poll(device, info, timeout);
}

static CyderPFN_vkVoidFunction cyder_wrap_vk_proc(const char *name, CyderPFN_vkVoidFunction p) {
    if (!name || !p) {
        return p;
    }
    if (strcmp(name, "vkWaitSemaphores") == 0) {
        return (CyderPFN_vkVoidFunction)vkWaitSemaphores;
    }
    if (strcmp(name, "vkWaitSemaphoresKHR") == 0) {
        return (CyderPFN_vkVoidFunction)vkWaitSemaphoresKHR;
    }
    if (strcmp(name, "vkGetDeviceProcAddr") == 0) {
        if (p != (CyderPFN_vkVoidFunction)vkGetDeviceProcAddr) {
            real_vkGetDeviceProcAddr = (CyderPFN_vkVoidFunction (*)(CyderVkDevice, const char *))p;
        }
        return (CyderPFN_vkVoidFunction)vkGetDeviceProcAddr;
    }
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) {
        if (p != (CyderPFN_vkVoidFunction)vkGetInstanceProcAddr) {
            real_vkGetInstanceProcAddr = (CyderPFN_vkVoidFunction (*)(CyderVkInstance, const char *))p;
        }
        return (CyderPFN_vkVoidFunction)vkGetInstanceProcAddr;
    }
    if (strcmp(name, "vkGetSemaphoreCounterValue") == 0) {
        real_vkGetSemaphoreCounterValue =
            (CyderVkResult (*)(CyderVkDevice, CyderVkSemaphore, uint64_t *))p;
        return p;
    }
    if (strcmp(name, "vkGetSemaphoreCounterValueKHR") == 0) {
        real_vkGetSemaphoreCounterValueKHR =
            (CyderVkResult (*)(CyderVkDevice, CyderVkSemaphore, uint64_t *))p;
        return p;
    }
    return p;
}

__attribute__((visibility("default"))) CyderPFN_vkVoidFunction
vkGetDeviceProcAddr(CyderVkDevice device, const char *name) {
    if (!real_vkGetDeviceProcAddr) {
        return NULL;
    }
    return cyder_wrap_vk_proc(name, real_vkGetDeviceProcAddr(device, name));
}

__attribute__((visibility("default"))) CyderPFN_vkVoidFunction
vkGetInstanceProcAddr(CyderVkInstance instance, const char *name) {
    if (!real_vkGetInstanceProcAddr) {
        return NULL;
    }
    if (name && strcmp(name, "vkGetDeviceProcAddr") == 0) {
        CyderPFN_vkVoidFunction p = real_vkGetInstanceProcAddr(instance, name);
        if (p && p != (CyderPFN_vkVoidFunction)vkGetDeviceProcAddr) {
            real_vkGetDeviceProcAddr = (CyderPFN_vkVoidFunction (*)(CyderVkDevice, const char *))p;
        }
        return (CyderPFN_vkVoidFunction)vkGetDeviceProcAddr;
    }
    return cyder_wrap_vk_proc(name, real_vkGetInstanceProcAddr(instance, name));
}

__attribute__((visibility("default"))) CyderPFN_vkVoidFunction
vk_icdGetInstanceProcAddr(CyderVkInstance instance, const char *name) {
    if (!real_vk_icdGetInstanceProcAddr) {
        return vkGetInstanceProcAddr(instance, name);
    }
    if (name && strcmp(name, "vkGetDeviceProcAddr") == 0) {
        CyderPFN_vkVoidFunction p = real_vk_icdGetInstanceProcAddr(instance, name);
        if (p && p != (CyderPFN_vkVoidFunction)vkGetDeviceProcAddr) {
            real_vkGetDeviceProcAddr = (CyderPFN_vkVoidFunction (*)(CyderVkDevice, const char *))p;
        }
        return (CyderPFN_vkVoidFunction)vkGetDeviceProcAddr;
    }
    if (name && strcmp(name, "vkGetInstanceProcAddr") == 0) {
        return (CyderPFN_vkVoidFunction)vkGetInstanceProcAddr;
    }
    return cyder_wrap_vk_proc(name, real_vk_icdGetInstanceProcAddr(instance, name));
}

__attribute__((constructor)) static void cyder_mvk_wait_poll_init(void) {
    (void)cyder_mvk_wait_poll_marker;

    void *mvk = dlopen("@loader_path/libMoltenVK.real.dylib", RTLD_NOLOAD | RTLD_NOW);
    if (!mvk) {
        mvk = dlopen("@loader_path/libMoltenVK.real.dylib", RTLD_NOW | RTLD_LOCAL);
    }
    if (!mvk) {
        return;
    }
    real_vkGetSemaphoreCounterValue = dlsym(mvk, "vkGetSemaphoreCounterValue");
    real_vkGetSemaphoreCounterValueKHR = dlsym(mvk, "vkGetSemaphoreCounterValueKHR");
    real_vkWaitSemaphores = dlsym(mvk, "vkWaitSemaphores");
    real_vkWaitSemaphoresKHR = dlsym(mvk, "vkWaitSemaphoresKHR");
    real_vkGetDeviceProcAddr = dlsym(mvk, "vkGetDeviceProcAddr");
    real_vkGetInstanceProcAddr = dlsym(mvk, "vkGetInstanceProcAddr");
    real_vk_icdGetInstanceProcAddr = dlsym(mvk, "vk_icdGetInstanceProcAddr");
}
