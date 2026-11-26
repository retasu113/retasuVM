#include "uefi.h"
#include "child_image.h"

static EFI_GUID guidLoadedImage = {0x5B1B31A1, 0x9562, 0x11D2, {0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B}};
static EFI_GUID guidGOP = {0x9042A9DE, 0x23DC, 0x4A38, {0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A}};
static EFI_GUID guidBlockIO = {0x964E5B21, 0x6459, 0x11D2, {0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B}};
static UINT8 mapBuffer[4096];
static EFI_HANDLE handleBuffer[8];

EFI_STATUS EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    gST = SystemTable;
    EFI_BOOT_SERVICES *bs = SystemTable->BootServices;
    EFI_STATUS status;

    // 1. Loaded Image プロトコル
    EFI_LOADED_IMAGE_PROTOCOL *loaded = 0;
    status = bs->LocateProtocol(&guidLoadedImage, 0, (VOID **)&loaded);
    if (status == EFI_SUCCESS && loaded && loaded->ImageBase == (VOID *)0x200000 && loaded->ImageSize > 0) {
        print("LOADEDIMAGE OK");
    } else { print("LOADEDIMAGE NG"); }

    // 2. LoadImage / StartImage / UnloadImage
    EFI_HANDLE childHandle = 0;
    status = bs->LoadImage(0, ImageHandle, 0, (VOID *)child_image, child_image_size, &childHandle);
    if (status == EFI_SUCCESS && childHandle != 0) {
        print("LOADIMAGE OK");
        status = bs->StartImage(childHandle, 0, 0);
        if (status == (EFI_STATUS)42) { print("STARTIMAGE OK"); } else { print("STARTIMAGE NG"); }
        status = bs->UnloadImage(childHandle);
        if (status == EFI_SUCCESS) { print("UNLOAD OK"); } else { print("UNLOAD NG"); }
    } else { print("LOADIMAGE NG"); }

    // 3. GOP: QueryMode + Blt + フレームバッファ読み戻し
    EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = 0;
    status = bs->LocateProtocol(&guidGOP, 0, (VOID **)&gop);
    if (status == EFI_SUCCESS && gop) {
        UINTN infoSize = 0;
        EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = 0;
        status = gop->QueryMode(gop, 0, &infoSize, &info);
        int gopOK = status == EFI_SUCCESS && info
            && info->HorizontalResolution == 640 && info->VerticalResolution == 400;
        EFI_GRAPHICS_OUTPUT_BLT_PIXEL pixel = {0x11, 0x22, 0x33, 0x00};
        status = gop->Blt(gop, &pixel, 0, 0, 0, 5, 5, 20, 20, 0);
        UINT32 *fb = (UINT32 *)(UINTN)gop->Mode->FrameBufferBase;
        UINT32 value = fb[10 * 640 + 10];
        if (gopOK && status == EFI_SUCCESS && value == 0x00332211ULL) {
            print("GOP OK");
        } else { print("GOP NG"); }
    } else { print("GOP NG"); }

    // 4. イベント / タイマ
    EFI_EVENT event = 0;
    status = bs->CreateEvent(0x80000000, 0, 0, 0, &event);
    if (status == EFI_SUCCESS) {
        bs->SetTimer(event, 2, 1000000); // 相対 100 ms
        EFI_STATUS early = bs->CheckEvent(event);
        bs->Stall(200000); // 200 ms
        EFI_STATUS late = bs->CheckEvent(event);
        if ((early & EFI_ERROR_BIT) && late == EFI_SUCCESS) { print("EVENT OK"); }
        else { print("EVENT NG"); }
        bs->CloseEvent(event);
    } else { print("EVENT NG"); }

    // 5. WaitForEvent
    EFI_EVENT event2 = 0;
    status = bs->CreateEvent(0x80000000, 0, 0, 0, &event2);
    if (status == EFI_SUCCESS) {
        bs->SetTimer(event2, 2, 500000); // 相対 50 ms
        UINTN index = 99;
        status = bs->WaitForEvent(1, &event2, &index);
        if (status == EFI_SUCCESS && index == 0) { print("WAIT OK"); } else { print("WAIT NG"); }
        bs->CloseEvent(event2);
    } else { print("WAIT NG"); }

    // 6. LocateHandle（2 段階: サイズ問い合わせ → 取得）
    UINTN bufferSize = 0;
    status = bs->LocateHandle(2, &guidBlockIO, 0, &bufferSize, 0);
    if (status == (EFI_STATUS)0x8000000000000005ULL && bufferSize >= 8) {
        bufferSize = sizeof(handleBuffer);
        status = bs->LocateHandle(2, &guidBlockIO, 0, &bufferSize, handleBuffer);
        if (status == EFI_SUCCESS && bufferSize >= 8 && handleBuffer[0] != 0) {
            print("LOCATEHANDLE OK");
        } else { print("LOCATEHANDLE NG"); }
    } else { print("LOCATEHANDLE NG"); }

    // 7. ランタイム GetTime
    EFI_TIME time;
    status = SystemTable->RuntimeServices->GetTime(&time, 0);
    if (status == EFI_SUCCESS && time.Year >= 2025 && time.Year <= 2030
        && time.Month >= 1 && time.Month <= 12 && time.Day >= 1 && time.Day <= 31) {
        print("GETTIME OK");
    } else { print("GETTIME NG"); }

    // 8. ExitBootServices 後にブートサービスが無効化されること
    UINTN mapSize = sizeof(mapBuffer);
    UINTN mapKey = 0, descriptorSize = 0;
    UINT32 descriptorVersion = 0;
    status = bs->GetMemoryMap(&mapSize, mapBuffer, &mapKey, &descriptorSize, &descriptorVersion);
    if (status == EFI_SUCCESS) {
        status = bs->ExitBootServices(ImageHandle, mapKey);
        if (status == EFI_SUCCESS) {
            VOID *pool = 0;
            EFI_STATUS after = bs->AllocatePool(2, 64, &pool);
            if (after & EFI_ERROR_BIT) { print("EBS OK"); } else { print("EBS NG"); }
        } else { print("EBS NG"); }
    } else { print("EBS NG"); }

    print("UEFI3 DONE");
    return EFI_SUCCESS;
}
