/* Standalone Win32 diagnostic. No registry writes, injection, or game hooks.
 * font OUTPUT.bmp
 * stretch INPUT.bmp WIDTH HEIGHT MODE OUTPUT.bmp (MODE 3 or 4)
 * Input must be the top-down 32-bit BI_RGB BMP produced by this probe.
 * Outputs use CREATE_NEW and never replace an existing file. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <stdlib.h>
static int save(const wchar_t *name,int w,int h,void *bits){
    BITMAPFILEHEADER f={
        0
    };
    BITMAPINFOHEADER i={
        0
    };
    DWORD n;
    HANDLE out=CreateFileW(name,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);
    if(out==INVALID_HANDLE_VALUE)return 20;
    f.bfType=0x4d42;
    f.bfOffBits=sizeof(f)+sizeof(i);
    f.bfSize=f.bfOffBits+w*h*4;
    i.biSize=sizeof(i);
    i.biWidth=w;
    i.biHeight=-h;
    i.biPlanes=1;
    i.biBitCount=32;
    i.biCompression=BI_RGB;
    BOOL ok=WriteFile(out,&f,sizeof(f),&n,NULL)&&n==sizeof(f)&&WriteFile(out,&i,sizeof(i),&n,NULL)&&n==sizeof(i)&&WriteFile(out,bits,w*h*4,&n,NULL)&&n==(DWORD)(w*h*4);
    CloseHandle(out);
    return ok?0:21;
}
static HBITMAP make(HDC dc,int w,int h,void **bits){
    BITMAPINFO i={
        0
    };
    i.bmiHeader.biSize=sizeof(i.bmiHeader);
    i.bmiHeader.biWidth=w;
    i.bmiHeader.biHeight=-h;
    i.bmiHeader.biPlanes=1;
    i.bmiHeader.biBitCount=32;
    return CreateDIBSection(dc,&i,DIB_RGB_COLORS,bits,NULL,0);
}
int wmain(int argc,wchar_t **argv){
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if(argc<3)return 2;
    if(!wcscmp(argv[1],L"font")){
        HDC dc=CreateCompatibleDC(NULL);
        void *bits;
        HBITMAP bmp=make(dc,640,96,&bits),old=SelectObject(dc,bmp);
        if(!dc||!bmp||!old)return 24;
        RECT r={
            0,0,640,96
        };
        FillRect(dc,&r,GetStockObject(WHITE_BRUSH));
        SetTextColor(dc,RGB(0,0,0));
        SetBkColor(dc,RGB(255,255,255));
        HFONT f=CreateFontW(-31,0,0,0,FW_NORMAL,FALSE,FALSE,FALSE,DEFAULT_CHARSET,OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,DEFAULT_QUALITY,DEFAULT_PITCH,L"Arial"),of=SelectObject(dc,f);
        if(!f||!of)return 24;
        const wchar_t *s=L"Font smoothing ABCDE abcde 123456";
        if(!TextOutW(dc,8,16,s,wcslen(s)))return 26;
        GdiFlush();
        BOOL smoothing=FALSE;
        UINT type=0;
        if(!SystemParametersInfoW(SPI_GETFONTSMOOTHING,0,&smoothing,0))return 27;
        if(!SystemParametersInfoW(SPI_GETFONTSMOOTHINGTYPE,0,&type,0))return 27;
        unsigned edge=0;
        DWORD *px=bits;
        for(int k=0;k<640*96;k++){
            BYTE v=px[k]&255;
            if(v&&v<255)edge++;
        }
        int result=save(argv[2],640,96,bits);
        printf("{\"font_smoothing\":%d,\"font_smoothing_type\":%u,\"intermediate_blue_pixels\":%u,\"save_exit\":%d}\n",smoothing,type,edge,result);
        SelectObject(dc,of);
        DeleteObject(f);
        SelectObject(dc,old);
        DeleteObject(bmp);
        DeleteDC(dc);
        return result;
    }
    if(!wcscmp(argv[1],L"stretch")){
        if(argc!=7)return 3;
        int w=_wtoi(argv[3]),h=_wtoi(argv[4]),mode=_wtoi(argv[5]);
        if(w<1||h<1||w>4000||h>4000||(mode!=3&&mode!=4))return 4;
        HANDLE input=CreateFileW(argv[2],GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
        if(input==INVALID_HANDLE_VALUE)return 5;
        BITMAPFILEHEADER fh;
        BITMAPINFOHEADER ih;
        DWORD got;
        if(!ReadFile(input,&fh,sizeof(fh),&got,NULL)||got!=sizeof(fh))return 22;
        if(!ReadFile(input,&ih,sizeof(ih),&got,NULL)||got!=sizeof(ih))return 22;
        if(fh.bfType!=0x4d42||ih.biSize!=40||ih.biPlanes!=1||ih.biBitCount!=32||ih.biCompression!=BI_RGB||ih.biHeight>=0||ih.biHeight< -4000||ih.biWidth<1||ih.biWidth>4000||fh.bfOffBits<54)return 22;
        HDC sd=CreateCompatibleDC(NULL),dd=CreateCompatibleDC(NULL);
        void *source_bits,*bits;
        HBITMAP src=make(sd,ih.biWidth,-ih.biHeight,&source_bits),dst=make(dd,w,h,&bits),so=SelectObject(sd,src),dold=SelectObject(dd,dst);
        if(!src||!dst||!so||!dold)return 24;
        SetFilePointer(input,fh.bfOffBits,NULL,FILE_BEGIN);
        DWORD bytes=ih.biWidth*(-ih.biHeight)*4;
        if(!ReadFile(input,source_bits,bytes,&got,NULL)||got!=bytes)return 23;
        CloseHandle(input);
        for(DWORD k=0;k<bytes/4;k++)((DWORD*)source_bits)[k]|=0xff000000;
        BITMAP bm;
        GetObjectW(src,sizeof(bm),&bm);
        COLORREF source_pixel=GetPixel(sd,0,0);
        if(!SetStretchBltMode(dd,mode))return 25;
        if(mode==HALFTONE&&!SetBrushOrgEx(dd,0,0,NULL))return 25;
        BOOL ok=StretchBlt(dd,0,0,w,h,sd,0,0,bm.bmWidth,bm.bmHeight,SRCCOPY);
        GdiFlush();
        COLORREF destination_pixel=GetPixel(dd,0,0);
        if(source_pixel==CLR_INVALID||destination_pixel==CLR_INVALID)return 28;
        fprintf(stderr,"source_pixel=%lu destination_pixel=%lu raw_pixel=%08lx\n",source_pixel,destination_pixel,((DWORD*)bits)[0]);
        int result=ok?save(argv[6],w,h,bits):6;
        printf("{\"source\":[%ld,%ld],\"destination\":[%d,%d],\"stretch_mode\":%d,\"save_exit\":%d}\n",bm.bmWidth,bm.bmHeight,w,h,mode,result);
        SelectObject(sd,so);
        SelectObject(dd,dold);
        DeleteObject(src);
        DeleteObject(dst);
        DeleteDC(sd);
        DeleteDC(dd);
        return result;
    }
    return 1;
}
