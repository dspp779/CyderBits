#include <stdio.h>
#include <wchar.h>
#include <windows.h>

static void print_environment( const char *label, const wchar_t *name )
{
    wchar_t value[256];
    DWORD length;
    const wchar_t *ptr;

    printf( "ENV_%s=", label );
    length = GetEnvironmentVariableW( name, value, sizeof(value) / sizeof(value[0]) );
    if (!length || length >= sizeof(value) / sizeof(value[0]))
    {
        puts( "<unset>" );
        return;
    }
    for (ptr = value; *ptr; ++ptr)
    {
        unsigned int ch = *ptr;
        if (ch >= 0x20 && ch <= 0x7e) putchar( ch );
        else printf( "\\u%04x", ch );
    }
    putchar( '\n' );
}

int wmain( int argc, wchar_t **argv )
{
    int i;

    for (i = 0; i < argc; ++i)
    {
        const wchar_t *ptr;
        printf( "ARG%d=", i );
        for (ptr = argv[i]; *ptr; ++ptr)
        {
            unsigned int ch = *ptr;
            if (ch >= 0x20 && ch <= 0x7e) putchar( ch );
            else printf( "\\u%04x", ch );
        }
        putchar( '\n' );
    }
    print_environment( "TEST_SET", L"TEST_SET" );
    print_environment( "TEST_REMOVE", L"TEST_REMOVE" );
    print_environment( "CYDER_GRAPHICS_BACKEND", L"CYDER_GRAPHICS_BACKEND" );
    print_environment( "CYDER_WINED3D_RENDERER", L"CYDER_WINED3D_RENDERER" );
    return 0;
}
