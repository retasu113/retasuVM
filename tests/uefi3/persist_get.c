#include "uefi.h"
static EFI_GUID vendor = {0x12345678, 0x9ABC, 0xDEF0, {0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88}};
EFI_STATUS EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    gST = SystemTable;
    CHAR16 name[] = {'P', 'e', 'r', 's', 'i', 's', 't', 'T', 'e', 's', 't', 0};
    UINT8 data[8];
    UINTN size = sizeof(data);
    UINT32 attributes = 0;
    EFI_STATUS status = SystemTable->RuntimeServices->GetVariable(name, &vendor, &attributes, &size, data);
    if (status == EFI_SUCCESS && size == 4 && attributes == 7
        && data[0] == 0xDE && data[1] == 0xAD && data[2] == 0xBE && data[3] == 0xEF) {
        print("PERSIST OK");
    } else { print("PERSIST NG"); }
    return EFI_SUCCESS;
}
