#include "uefi.h"
static EFI_GUID vendor = {0x12345678, 0x9ABC, 0xDEF0, {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}};
EFI_STATUS EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    gST = SystemTable;
    CHAR16 name[] = {'P', 'e', 'r', 's', 'i', 's', 't', 'T', 'e', 's', 't', 0};
    UINT8 data[4] = {0xDE, 0xAD, 0xBE, 0xEF};
    EFI_STATUS status = SystemTable->RuntimeServices->SetVariable(name, &vendor, 7, 4, data);
    print(status == EFI_SUCCESS ? "SETVAR DONE" : "SETVAR NG");
    return EFI_SUCCESS;
}
