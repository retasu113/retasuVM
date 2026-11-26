#include "uefi.h"
#include "child_image.h"

// ---- 追加の型定義（uefi.h に無いもの） ----
typedef struct { UINT16 ScanCode; CHAR16 UnicodeChar; } EFI_INPUT_KEY;
typedef EFI_STATUS (*EFI_TEXT_INPUT_READ_KEY)(VOID *This, EFI_INPUT_KEY *Key);
typedef struct { VOID *Reset; EFI_TEXT_INPUT_READ_KEY ReadKeyStroke; EFI_EVENT WaitForEvent; } EFI_SIMPLE_TEXT_INPUT_PROTOCOL;

typedef EFI_STATUS (*EFI_INSTALL_PROTOCOL)(EFI_HANDLE *Handle, EFI_GUID *Protocol, UINTN InterfaceType, VOID *Interface);
typedef EFI_STATUS (*EFI_CONNECT_CONTROLLER)(EFI_HANDLE Controller, EFI_HANDLE *DriverImageHandle, VOID *RemainingDevicePath, UINT8 Recursive);
typedef EFI_STATUS (*EFI_REGISTER_NOTIFY)(EFI_GUID *Protocol, EFI_EVENT Event, VOID **Registration);
typedef EFI_STATUS (*EFI_LOCATE_HANDLE_BUFFER)(UINTN SearchType, EFI_GUID *Protocol, VOID *SearchKey, UINTN *NoHandles, EFI_HANDLE **Buffer);

typedef EFI_STATUS (*EFI_BINDING_SUPPORTED)(VOID *This, EFI_HANDLE Controller, VOID *RemainingPath);
typedef EFI_STATUS (*EFI_BINDING_START)(VOID *This, EFI_HANDLE Controller, VOID *RemainingPath);
typedef EFI_STATUS (*EFI_BINDING_STOP)(VOID *This, EFI_HANDLE Controller, UINTN NumberOfChildren, EFI_HANDLE *ChildBuffer);
typedef struct { EFI_BINDING_SUPPORTED Supported; EFI_BINDING_START Start; EFI_BINDING_STOP Stop; UINT32 Version; EFI_HANDLE ImageHandle; EFI_HANDLE DriverBindingHandle; } EFI_DRIVER_BINDING_PROTOCOL;

static EFI_GUID guidBlockIO = {0x964E5B21, 0x6459, 0x11D2, {0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B}};
static EFI_GUID guidSFS = {0x964E5B22, 0x6459, 0x11D2, {0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B}};
static EFI_GUID guidDriverBinding = {0x18A031AB, 0xB443, 0x4D1A, {0xA5, 0xC0, 0x0C, 0x09, 0x26, 0x1E, 0x9F, 0x71}};
static EFI_GUID guidCustom = {0xDEADBEEF, 0x1234, 0x5678, {0x9A, 0xBC, 0xDE, 0xF0, 0x11, 0x22, 0x33, 0x44}};

static volatile UINT32 notifyFlag = 0;
static volatile UINT32 protoFlag = 0;
static volatile UINT32 ebsFlag = 0;
static volatile UINT32 supportedFlag = 0;
static volatile UINT32 startedFlag = 0;
static volatile UINT32 stoppedFlag = 0;

// 通知の配送はセッションループの合間に起きるため、フラグが立つまで
// 短いスピンを繰り返して待つ。
static int waitFlag(volatile UINT32 *flag, UINT32 value) {
    for (int t = 0; t < 200; t++) {
        if (*flag == value) return 1;
        for (volatile int i = 0; i < 50000; i++) { }
    }
    return *flag == value;
}

__attribute__((ms_abi)) static void notifyFn(EFI_EVENT event, VOID *context) {
    *(volatile UINT32 *)context = 0xCAFEBABE;
}
__attribute__((ms_abi)) static void protoNotifyFn(EFI_EVENT event, VOID *context) {
    *(volatile UINT32 *)context = 1;
}
__attribute__((ms_abi)) static void ebsNotifyFn(EFI_EVENT event, VOID *context) {
    *(volatile UINT32 *)context = 1;
}
__attribute__((ms_abi)) static EFI_STATUS drvSupported(VOID *This, EFI_HANDLE Controller, VOID *RemainingPath) {
    supportedFlag = 1;
    return EFI_SUCCESS;
}
__attribute__((ms_abi)) static EFI_STATUS drvStart(VOID *This, EFI_HANDLE Controller, VOID *RemainingPath) {
    startedFlag = 1;
    return EFI_SUCCESS;
}
__attribute__((ms_abi)) static EFI_STATUS drvStop(VOID *This, EFI_HANDLE Controller, UINTN NumberOfChildren, EFI_HANDLE *ChildBuffer) {
    stoppedFlag = 1;
    return EFI_SUCCESS;
}

static EFI_DRIVER_BINDING_PROTOCOL binding = { drvSupported, drvStart, drvStop, 0x10, 0, 0 };
static UINT8 mapBuffer[8192];

EFI_STATUS EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    gST = SystemTable;
    EFI_BOOT_SERVICES *bs = SystemTable->BootServices;
    EFI_STATUS status;

    // 1. ConIn: キー入力を読む（ハーネスが遅延送信する）
    EFI_SIMPLE_TEXT_INPUT_PROTOCOL *conIn = (EFI_SIMPLE_TEXT_INPUT_PROTOCOL *)SystemTable->ConIn;
    if (!conIn || !conIn->ReadKeyStroke) { print("CONIN NG (no protocol)"); return 1; }
    EFI_INPUT_KEY key;
    int got = 0;
    for (int i = 0; i < 500 && !got; i++) {
        status = conIn->ReadKeyStroke(conIn, &key);
        if (status == EFI_SUCCESS) got = 1;
        else bs->Stall(10000);
    }
    print(got && key.UnicodeChar == 'Z' ? "CONIN OK" : "CONIN NG");

    // 2. WaitForEvent でキー待ち
    {
        UINTN index = 99;
        EFI_EVENT waitEvent = conIn->WaitForEvent;
        status = bs->WaitForEvent(1, &waitEvent, &index);
        EFI_INPUT_KEY key2;
        EFI_STATUS status2 = conIn->ReadKeyStroke(conIn, &key2);
        print(status == EFI_SUCCESS && index == 0 && status2 == EFI_SUCCESS && key2.UnicodeChar == 'Q'
              ? "WAITKEY OK" : "WAITKEY NG");
    }

    // 3. イベント通知関数（SignalEvent）
    {
        EFI_EVENT event = 0;
        status = bs->CreateEvent(0x200, 0, (VOID *)notifyFn, (VOID *)&notifyFlag, &event);
        if (status != EFI_SUCCESS) { print("NOTIFY NG (create)"); return 1; }
        bs->SignalEvent(event);
        print(waitFlag(&notifyFlag, 0xCAFEBABE) ? "NOTIFY OK" : "NOTIFY NG");
        bs->CloseEvent(event);
    }

    // 4. プロトコル通知（RegisterProtocolNotify + InstallProtocolInterface）
    {
        EFI_EVENT event = 0;
        VOID *registration = 0;
        status = bs->CreateEvent(0x200, 0, (VOID *)protoNotifyFn, (VOID *)&protoFlag, &event);
        if (status != EFI_SUCCESS) { print("PROTONOTIFY NG (create)"); return 1; }
        EFI_REGISTER_NOTIFY registerNotify = (EFI_REGISTER_NOTIFY)bs->RegisterProtocolNotify;
        status = registerNotify(&guidCustom, event, &registration);
        if (status != EFI_SUCCESS) { print("PROTONOTIFY NG (register)"); return 1; }
        EFI_HANDLE handle = 0;
        static UINT8 dummyInterface[8];
        EFI_INSTALL_PROTOCOL install = (EFI_INSTALL_PROTOCOL)bs->InstallProtocolInterface;
        status = install(&handle, &guidCustom, 0, dummyInterface);
        print(status == EFI_SUCCESS && waitFlag(&protoFlag, 1) ? "PROTONOTIFY OK" : "PROTONOTIFY NG");
        bs->CloseEvent(event);
    }

    // 5. ドライババインディング（ConnectController / DisconnectController）
    {
        binding.ImageHandle = ImageHandle;
        EFI_HANDLE driverHandle = 0;
        EFI_INSTALL_PROTOCOL install = (EFI_INSTALL_PROTOCOL)bs->InstallProtocolInterface;
        status = install(&driverHandle, &guidDriverBinding, 0, &binding);
        if (status != EFI_SUCCESS) { print("DRIVER NG (install)"); return 1; }
        binding.DriverBindingHandle = driverHandle;
        // コントローラ = Block I/O を持つハンドル
        EFI_HANDLE *handles = 0;
        UINTN handleCount = 0;
        EFI_LOCATE_HANDLE_BUFFER locateBuffer = (EFI_LOCATE_HANDLE_BUFFER)bs->LocateHandleBuffer;
        status = locateBuffer(2, &guidBlockIO, 0, &handleCount, &handles);
        if (status != EFI_SUCCESS || handleCount == 0) { print("DRIVER NG (locate)"); return 1; }
        EFI_CONNECT_CONTROLLER connect = (EFI_CONNECT_CONTROLLER)bs->ConnectController;
        status = connect(handles[0], 0, 0, 0);
        print(status == EFI_SUCCESS && supportedFlag && startedFlag ? "DRIVER OK" : "DRIVER NG");
        EFI_CONNECT_CONTROLLER disconnect = (EFI_CONNECT_CONTROLLER)bs->DisconnectController;
        status = disconnect(handles[0], 0, 0, 0);
        print(status == EFI_SUCCESS && stoppedFlag ? "DRIVERSTOP OK" : "DRIVERSTOP NG");
    }

    // 6. LoadImage をデバイスパス（ファイル）経由で
    {
        EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *sfs = 0;
        status = bs->LocateProtocol(&guidSFS, 0, (VOID **)&sfs);
        if (status != EFI_SUCCESS) { print("DPLOAD NG (no SFS)"); return 1; }
        EFI_FILE_PROTOCOL *root = 0;
        status = sfs->OpenVolume(sfs, &root);
        if (status != EFI_SUCCESS) { print("DPLOAD NG (volume)"); return 1; }
        static CHAR16 childName[] = {'\\','C','H','I','L','D','.','E','F','I',0};
        EFI_FILE_PROTOCOL *file = 0;
        status = root->Open(root, &file, childName,
            EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0);
        if (status != EFI_SUCCESS) { print("DPLOAD NG (create)"); return 1; }
        UINTN writeSize = child_image_size;
        status = file->Write(file, &writeSize, (VOID *)child_image);
        file->Close(file);
        root->Close(root);
        if (status != EFI_SUCCESS) { print("DPLOAD NG (write)"); return 1; }
        // デバイスパス: PCI ノード + ファイルパス + 終端
        static UINT8 devicePath[6 + 26 + 4];
        devicePath[0] = 0x01; devicePath[1] = 0x01; devicePath[2] = 0x06; devicePath[3] = 0x00;
        devicePath[4] = 0x01; devicePath[5] = 0x01;
        devicePath[6] = 0x04; devicePath[7] = 0x04; devicePath[8] = 26; devicePath[9] = 0;
        const char *pathText = "\\CHILD.EFI";
        for (int i = 0; i < 11; i++) {
            devicePath[10 + i * 2] = (i < 10) ? (UINT8)pathText[i] : 0;
            devicePath[10 + i * 2 + 1] = 0;
        }
        devicePath[32] = 0x7F; devicePath[33] = 0xFF; devicePath[34] = 0x04; devicePath[35] = 0x00;
        EFI_HANDLE childHandle = 0;
        status = bs->LoadImage(0, ImageHandle, devicePath, 0, 0, &childHandle);
        if (status != EFI_SUCCESS || !childHandle) { print("DPLOAD NG (load)"); return 1; }
        status = bs->StartImage(childHandle, 0, 0);
        print(status == (EFI_STATUS)42 ? "DPLOAD OK" : "DPLOAD NG");
        bs->UnloadImage(childHandle);
    }

    // 7. ExitBootServices グループイベントの通知
    {
        EFI_EVENT event = 0;
        status = bs->CreateEvent(0x202, 0, (VOID *)ebsNotifyFn, (VOID *)&ebsFlag, &event);
        if (status != EFI_SUCCESS) { print("EBSNOTIFY NG (create)"); return 1; }
        UINTN mapSize = sizeof(mapBuffer), mapKey = 0, descriptorSize = 0;
        UINT32 descriptorVersion = 0;
        status = bs->GetMemoryMap(&mapSize, mapBuffer, &mapKey, &descriptorSize, &descriptorVersion);
        if (status != EFI_SUCCESS) { print("EBSNOTIFY NG (map)"); return 1; }
        status = bs->ExitBootServices(ImageHandle, mapKey);
        if (status != EFI_SUCCESS) { print("EBSNOTIFY NG (ebs)"); return 1; }
        print(waitFlag(&ebsFlag, 1) ? "EBSNOTIFY OK" : "EBSNOTIFY NG");
    }

    print("UEFI4 DONE");
    return 0;
}
