#include "uefi.h"

static EFI_GUID guidSFS = {0x964E5B22, 0x6459, 0x11D2, {0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B}};
static CHAR16 targetName[] = {'L','o','n','g',' ','F','i','l','e',' ','N','a','m','e',' ','T','e','s','t','.','t','x','t',0};

static int nameEquals(const CHAR16 *a, const CHAR16 *b) {
    int i = 0;
    while (a[i] && b[i]) { if (a[i] != b[i]) return 0; i++; }
    return a[i] == b[i];
}

static int countEntries(EFI_FILE_PROTOCOL *root) {
    // ディレクトリ読み取りは位置依存なので、開き直して数える
    return -1; // 未使用（列挙は呼び出し側で SetPosition の代わりに開き直す）
}

static int enumerateCount(EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *sfs) {
    EFI_FILE_PROTOCOL *root = 0;
    if (sfs->OpenVolume(sfs, &root) != EFI_SUCCESS) return -1;
    int count = 0;
    UINT8 buffer[512];
    for (;;) {
        UINTN size = sizeof(buffer);
        EFI_STATUS status = root->Read(root, &size, buffer);
        if (status != EFI_SUCCESS || size == 0) break;
        EFI_FILE_INFO *info = (EFI_FILE_INFO *)buffer;
        if (nameEquals(info->FileName, targetName)) count++;
    }
    root->Close(root);
    return count;
}

static EFI_STATUS writeFile(EFI_FILE_PROTOCOL *root, const char *contents, UINTN length) {
    EFI_FILE_PROTOCOL *file = 0;
    EFI_STATUS status = root->Open(root, &file, targetName,
        EFI_FILE_MODE_READ | EFI_FILE_MODE_WRITE | EFI_FILE_MODE_CREATE, 0);
    if (status != EFI_SUCCESS) return status;
    UINTN size = length;
    status = file->Write(file, &size, (VOID *)contents);
    file->Close(file);
    return status;
}

EFI_STATUS EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    gST = SystemTable;
    EFI_BOOT_SERVICES *bs = SystemTable->BootServices;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL *sfs = 0;
    EFI_STATUS status = bs->LocateProtocol(&guidSFS, 0, (VOID **)&sfs);
    if (status != EFI_SUCCESS || !sfs) { print("LFN NG (no SFS)"); return 1; }
    EFI_FILE_PROTOCOL *root = 0;
    status = sfs->OpenVolume(sfs, &root);
    if (status != EFI_SUCCESS) { print("LFN NG (open volume)"); return 1; }

    // 1. ロングネームで作成
    status = writeFile(root, "HELLO-LFN", 9);
    print(status == EFI_SUCCESS ? "LFN CREATE OK" : "LFN CREATE NG");

    // 2. 列挙で 1 件だけ見つかる
    print(enumerateCount(sfs) == 1 ? "LFN ENUM1 OK" : "LFN ENUM1 NG");

    // 3. ロングネームで開いて読み戻し
    EFI_FILE_PROTOCOL *file = 0;
    status = root->Open(root, &file, targetName, EFI_FILE_MODE_READ, 0);
    if (status == EFI_SUCCESS) {
        UINT8 data[16];
        UINTN size = sizeof(data);
        status = file->Read(file, &size, data);
        int ok = status == EFI_SUCCESS && size == 9;
        const char *expected = "HELLO-LFN";
        for (int i = 0; ok && i < 9; i++) if (data[i] != (UINT8)expected[i]) ok = 0;
        print(ok ? "LFN READ OK" : "LFN READ NG");
        file->Close(file);
    } else { print("LFN READ NG"); }

    // 4. 同名で上書き → エントリが重複しない
    status = writeFile(root, "V2", 2);
    print(status == EFI_SUCCESS && enumerateCount(sfs) == 1 ? "LFN OVERWRITE OK" : "LFN OVERWRITE NG");

    // 5. 削除 → 列挙で 0 件（LFN エントリも残らない）
    file = 0;
    status = root->Open(root, &file, targetName, EFI_FILE_MODE_READ, 0);
    if (status == EFI_SUCCESS) {
        status = file->Delete(file);
        print(status == EFI_SUCCESS && enumerateCount(sfs) == 0 ? "LFN DELETE OK" : "LFN DELETE NG");
    } else { print("LFN DELETE NG"); }

    root->Close(root);
    print("LFN DONE");
    return EFI_SUCCESS;
}
