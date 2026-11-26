#include "uefi.h"
EFI_STATUS EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    gST = SystemTable;
    print("CHILD RUNNING");
    return (EFI_STATUS)42;
}
