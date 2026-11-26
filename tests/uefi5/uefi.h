// 最小 UEFI 型定義（テスト用、freestanding）
#ifndef UEFI_TEST_H
#define UEFI_TEST_H
typedef unsigned char UINT8;
typedef unsigned short UINT16;
typedef unsigned int UINT32;
typedef unsigned long long UINT64;
typedef unsigned long long UINTN;
typedef short INT16;
typedef int INT32;
typedef long long INTN;
typedef unsigned short CHAR16;
typedef void VOID;
typedef UINT64 EFI_STATUS;
typedef VOID *EFI_HANDLE;
typedef VOID *EFI_EVENT;
#define EFI_SUCCESS 0
#define EFI_ERROR_BIT (1ULL << 63)
typedef struct { UINT32 Data1; UINT16 Data2; UINT16 Data3; UINT8 Data4[8]; } EFI_GUID;
typedef struct { UINT16 Year; UINT8 Month; UINT8 Day; UINT8 Hour; UINT8 Minute; UINT8 Second; UINT8 Pad1; UINT32 Nanosecond; INT16 TimeZone; UINT8 Daylight; UINT8 Pad2; } EFI_TIME;

struct EFI_SYSTEM_TABLE;
typedef EFI_STATUS (*EFI_TEXT_OUTPUT_STRING)(VOID *This, CHAR16 *String);
typedef struct {
    VOID *Reset; EFI_TEXT_OUTPUT_STRING OutputString; VOID *TestString;
    VOID *QueryMode; VOID *SetMode; VOID *SetAttribute; VOID *ClearScreen;
    VOID *SetCursorPosition; VOID *EnableCursor; VOID *Mode;
} EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL;

typedef struct {
    UINT32 Revision; EFI_HANDLE ParentHandle; struct EFI_SYSTEM_TABLE *SystemTable;
    EFI_HANDLE DeviceHandle; VOID *FilePath; VOID *Reserved;
    UINT32 LoadOptionsSize; VOID *LoadOptions;
    VOID *ImageBase; UINT64 ImageSize; UINT32 ImageCodeType; UINT32 ImageDataType; VOID *Unload;
} EFI_LOADED_IMAGE_PROTOCOL;

typedef struct { UINT32 Version; UINT32 HorizontalResolution; UINT32 VerticalResolution; UINT32 PixelFormat; UINT32 PixelInfo[4]; UINT32 PixelsPerScanLine; } EFI_GRAPHICS_OUTPUT_MODE_INFORMATION;
typedef struct { UINT32 MaxMode; UINT32 Mode; EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info; UINTN SizeOfInfo; UINT64 FrameBufferBase; UINTN FrameBufferSize; } EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE;
typedef struct { UINT8 Blue; UINT8 Green; UINT8 Red; UINT8 Reserved; } EFI_GRAPHICS_OUTPUT_BLT_PIXEL;
typedef EFI_STATUS (*EFI_GOP_QUERY_MODE)(VOID *This, UINT32 ModeNumber, UINTN *SizeOfInfo, EFI_GRAPHICS_OUTPUT_MODE_INFORMATION **Info);
typedef EFI_STATUS (*EFI_GOP_SET_MODE)(VOID *This, UINT32 ModeNumber);
typedef EFI_STATUS (*EFI_GOP_BLT)(VOID *This, EFI_GRAPHICS_OUTPUT_BLT_PIXEL *BltBuffer, UINTN BltOperation, UINTN SourceX, UINTN SourceY, UINTN DestinationX, UINTN DestinationY, UINTN Width, UINTN Height, UINTN Delta);
typedef struct { EFI_GOP_QUERY_MODE QueryMode; EFI_GOP_SET_MODE SetMode; EFI_GOP_BLT Blt; EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE *Mode; } EFI_GRAPHICS_OUTPUT_PROTOCOL;

typedef EFI_STATUS (*EFI_ALLOCATE_POOL)(UINT32 PoolType, UINTN Size, VOID **Buffer);
typedef EFI_STATUS (*EFI_GET_MEMORY_MAP)(UINTN *MemoryMapSize, VOID *MemoryMap, UINTN *MapKey, UINTN *DescriptorSize, UINT32 *DescriptorVersion);
typedef EFI_STATUS (*EFI_EXIT_BOOT_SERVICES)(EFI_HANDLE ImageHandle, UINTN MapKey);
typedef EFI_STATUS (*EFI_STALL)(UINTN Microseconds);
typedef EFI_STATUS (*EFI_LOCATE_PROTOCOL)(EFI_GUID *Protocol, VOID *Registration, VOID **Interface);
typedef EFI_STATUS (*EFI_LOCATE_HANDLE)(UINTN SearchType, EFI_GUID *Protocol, VOID *SearchKey, UINTN *BufferSize, EFI_HANDLE *Buffer);
typedef EFI_STATUS (*EFI_LOAD_IMAGE)(UINT8 BootPolicy, EFI_HANDLE ParentImageHandle, VOID *DevicePath, VOID *SourceBuffer, UINTN SourceSize, EFI_HANDLE *ImageHandle);
typedef EFI_STATUS (*EFI_START_IMAGE)(EFI_HANDLE ImageHandle, UINTN *ExitDataSize, CHAR16 **ExitData);
typedef EFI_STATUS (*EFI_UNLOAD_IMAGE)(EFI_HANDLE ImageHandle);
typedef EFI_STATUS (*EFI_CREATE_EVENT)(UINT32 Type, UINTN NotifyTpl, VOID *NotifyFunction, VOID *NotifyContext, EFI_EVENT *Event);
typedef EFI_STATUS (*EFI_SET_TIMER)(EFI_EVENT Event, UINTN Type, UINT64 TriggerTime);
typedef EFI_STATUS (*EFI_CHECK_EVENT)(EFI_EVENT Event);
typedef EFI_STATUS (*EFI_WAIT_FOR_EVENT)(UINTN NumberOfEvents, EFI_EVENT *Event, UINTN *Index);
typedef EFI_STATUS (*EFI_CLOSE_EVENT)(EFI_EVENT Event);
typedef EFI_STATUS (*EFI_SIGNAL_EVENT)(EFI_EVENT Event);

typedef struct {
    UINT64 Signature; UINT32 Revision; UINT32 HeaderSize; UINT32 CRC32; UINT32 Reserved;
    VOID *RaiseTPL; VOID *RestoreTPL;
    VOID *AllocatePages; VOID *FreePages; EFI_GET_MEMORY_MAP GetMemoryMap;
    EFI_ALLOCATE_POOL AllocatePool; VOID *FreePool;
    EFI_CREATE_EVENT CreateEvent; EFI_SET_TIMER SetTimer; EFI_WAIT_FOR_EVENT WaitForEvent;
    EFI_SIGNAL_EVENT SignalEvent; EFI_CLOSE_EVENT CloseEvent; EFI_CHECK_EVENT CheckEvent;
    VOID *InstallProtocolInterface; VOID *ReinstallProtocolInterface; VOID *UninstallProtocolInterface;
    VOID *HandleProtocol; VOID *Reserved2; VOID *RegisterProtocolNotify;
    EFI_LOCATE_HANDLE LocateHandle; VOID *LocateDevicePath; VOID *InstallConfigurationTable;
    EFI_LOAD_IMAGE LoadImage; EFI_START_IMAGE StartImage; VOID *Exit; EFI_UNLOAD_IMAGE UnloadImage;
    EFI_EXIT_BOOT_SERVICES ExitBootServices; VOID *GetNextMonotonicCount; EFI_STALL Stall;
    VOID *SetWatchdogTimer; VOID *ConnectController; VOID *DisconnectController;
    VOID *OpenProtocol; VOID *CloseProtocol; VOID *OpenProtocolInformation;
    VOID *ProtocolsPerHandle; VOID *LocateHandleBuffer; EFI_LOCATE_PROTOCOL LocateProtocol;
    VOID *InstallMultipleProtocolInterfaces; VOID *UninstallMultipleProtocolInterfaces;
    VOID *CalculateCrc32; VOID *CopyMem; VOID *SetMem; VOID *CreateEventEx;
} EFI_BOOT_SERVICES;

typedef EFI_STATUS (*EFI_GET_TIME)(EFI_TIME *Time, VOID *Capabilities);
typedef EFI_STATUS (*EFI_GET_VARIABLE)(CHAR16 *VariableName, EFI_GUID *VendorGuid, UINT32 *Attributes, UINTN *DataSize, VOID *Data);
typedef EFI_STATUS (*EFI_SET_VARIABLE)(CHAR16 *VariableName, EFI_GUID *VendorGuid, UINT32 Attributes, UINTN DataSize, VOID *Data);
typedef struct {
    UINT64 Signature; UINT32 Revision; UINT32 HeaderSize; UINT32 CRC32; UINT32 Reserved;
    EFI_GET_TIME GetTime; VOID *SetTime; VOID *GetWakeupTime; VOID *SetWakeupTime;
    VOID *SetVirtualAddressMap; VOID *ConvertPointer;
    EFI_GET_VARIABLE GetVariable; VOID *GetNextVariableName; EFI_SET_VARIABLE SetVariable;
    VOID *GetNextHighMonotonicCount; VOID *ResetSystem;
    VOID *UpdateCapsule; VOID *QueryCapsuleCapabilities; VOID *QueryVariableInfo;
} EFI_RUNTIME_SERVICES;

typedef struct EFI_SYSTEM_TABLE {
    UINT64 Signature; UINT32 Revision; UINT32 HeaderSize; UINT32 CRC32; UINT32 Reserved;
    CHAR16 *FirmwareVendor; UINT32 FirmwareRevision;
    EFI_HANDLE ConsoleInHandle; VOID *ConIn;
    EFI_HANDLE ConsoleOutHandle; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *ConOut;
    EFI_HANDLE StandardErrorHandle; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL *StdErr;
    EFI_RUNTIME_SERVICES *RuntimeServices; EFI_BOOT_SERVICES *BootServices;
    UINTN NumberOfTableEntries; VOID *ConfigurationTable;
} EFI_SYSTEM_TABLE;

static EFI_SYSTEM_TABLE *gST;
static void print(const char *text) {
    CHAR16 buffer[128];
    int i = 0;
    while (text[i] && i < 120) { buffer[i] = (CHAR16)(unsigned char)text[i]; i++; }
    if (i + 1 < 127) { buffer[i++] = (CHAR16)'\r'; buffer[i++] = (CHAR16)'\n'; }
    buffer[i] = 0;
    gST->ConOut->OutputString(gST->ConOut, buffer);
}
#endif

// --- Simple File System / ファイルプロトコル（LFN テスト用） ---
typedef struct EFI_FILE_PROTOCOL EFI_FILE_PROTOCOL;
typedef EFI_STATUS (*EFI_FILE_OPEN)(EFI_FILE_PROTOCOL *This, EFI_FILE_PROTOCOL **NewHandle, CHAR16 *FileName, UINT64 OpenMode, UINT64 Attributes);
typedef EFI_STATUS (*EFI_FILE_CLOSE)(EFI_FILE_PROTOCOL *This);
typedef EFI_STATUS (*EFI_FILE_DELETE)(EFI_FILE_PROTOCOL *This);
typedef EFI_STATUS (*EFI_FILE_READ)(EFI_FILE_PROTOCOL *This, UINTN *BufferSize, VOID *Buffer);
typedef EFI_STATUS (*EFI_FILE_WRITE)(EFI_FILE_PROTOCOL *This, UINTN *BufferSize, VOID *Buffer);
typedef EFI_STATUS (*EFI_SFS_OPEN_VOLUME)(VOID *This, EFI_FILE_PROTOCOL **Root);
struct EFI_FILE_PROTOCOL {
    UINT64 Revision;
    EFI_FILE_OPEN Open; EFI_FILE_CLOSE Close; EFI_FILE_DELETE Delete;
    EFI_FILE_READ Read; EFI_FILE_WRITE Write;
    VOID *GetPosition; VOID *SetPosition; VOID *GetInfo; VOID *SetInfo; VOID *Flush;
};
typedef struct { UINT64 Revision; EFI_SFS_OPEN_VOLUME OpenVolume; } EFI_SIMPLE_FILE_SYSTEM_PROTOCOL;
typedef struct {
    UINT64 Size; UINT64 FileSize; UINT64 PhysicalSize;
    EFI_TIME CreateTime; EFI_TIME LastAccessTime; EFI_TIME ModificationTime;
    UINT64 Attribute; CHAR16 FileName[64];
} EFI_FILE_INFO;
#define EFI_FILE_MODE_READ 1
#define EFI_FILE_MODE_WRITE 2
#define EFI_FILE_MODE_CREATE (1ULL << 63)
