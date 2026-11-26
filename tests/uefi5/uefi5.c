#include "uefi.h"
#include "child_image.h"

// ---- 追加の型定義 ----
typedef EFI_STATUS (*EFI_ALLOCATE_PAGES)(UINTN Type, UINTN MemoryType, UINTN Pages, UINT64 *Memory);
typedef EFI_STATUS (*EFI_FREE_PAGES)(UINT64 Memory, UINTN Pages);
typedef EFI_STATUS (*EFI_FREE_POOL)(VOID *Buffer);
typedef EFI_STATUS (*EFI_CREATE_EVENT_EX)(UINT32 Type, UINTN NotifyTpl, VOID *NotifyFunction, VOID *NotifyContext, EFI_GUID *EventGroup, EFI_EVENT *Event);
typedef EFI_STATUS (*EFI_SET_VIRTUAL_ADDRESS_MAP)(UINTN MemoryMapSize, UINTN DescriptorSize, UINT32 DescriptorVersion, VOID *VirtualMap);
typedef EFI_STATUS (*EFI_CONVERT_POINTER)(UINTN DebugDisposition, VOID **Address);

#define EFI_INVALID_PARAMETER 0x8000000000000002ULL
#define EFI_UNSUPPORTED_STATUS 0x8000000000000003ULL
#define EFI_OUT_OF_RESOURCES 0x8000000000000009ULL
#define EFI_NOT_FOUND 0x800000000000000EULL
#define EFI_SECURITY_VIOLATION 0x800000000000001AULL

static EFI_GUID guidGOP = {0x9042A9DE, 0x23DC, 0x4A38, {0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A}};
static EFI_GUID guidGlobal = {0x8BE4DF61, 0x93CA, 0x11D2, {0xAA, 0x0D, 0x00, 0xE0, 0x98, 0x03, 0x2B, 0x8C}};
static EFI_GUID guidSecurityDB = {0xD719B2CB, 0x3D3A, 0x4596, {0xA3, 0xBC, 0xDA, 0xD0, 0x0E, 0x67, 0x65, 0x6F}};
static EFI_GUID guidCertSHA256 = {0xC1C41626, 0x504C, 0x4099, {0xAC, 0xA9, 0x41, 0xF9, 0x36, 0x93, 0x43, 0x28}};
static EFI_GUID guidEBSGroup = {0x27ABF055, 0xB1B8, 0x4C86, {0x80, 0x43, 0x74, 0x8E, 0xA6, 0xBF, 0xFD, 0xE9}};

// ---- SHA-256（FIPS 180-4、テスト用） ----
typedef struct { UINT32 state[8]; UINT64 bitLength; UINT8 data[64]; UINT32 dataLength; } SHA256_CTX;
static const UINT32 k256[64] = {
   0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
   0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
   0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
   0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
   0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
   0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
   0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
   0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define ROTR(x,n) (((x) >> (n)) | ((x) << (32 - (n))))
static void sha256Transform(SHA256_CTX *ctx, const UINT8 data[]) {
    UINT32 a,b,c,d,e,f,g,h,t1,t2,m[64];
    for (int i = 0, j = 0; i < 16; i++, j += 4) m[i] = ((UINT32)data[j] << 24) | ((UINT32)data[j+1] << 16) | ((UINT32)data[j+2] << 8) | ((UINT32)data[j+3]);
    for (int i = 16; i < 64; i++) {
        UINT32 s0 = ROTR(m[i-15],7) ^ ROTR(m[i-15],18) ^ (m[i-15] >> 3);
        UINT32 s1 = ROTR(m[i-2],17) ^ ROTR(m[i-2],19) ^ (m[i-2] >> 10);
        m[i] = m[i-16] + s0 + m[i-7] + s1;
    }
    a=ctx->state[0]; b=ctx->state[1]; c=ctx->state[2]; d=ctx->state[3];
    e=ctx->state[4]; f=ctx->state[5]; g=ctx->state[6]; h=ctx->state[7];
    for (int i = 0; i < 64; i++) {
        UINT32 S1 = ROTR(e,6) ^ ROTR(e,11) ^ ROTR(e,25);
        UINT32 ch = (e & f) ^ (~e & g);
        t1 = h + S1 + ch + k256[i] + m[i];
        UINT32 S0 = ROTR(a,2) ^ ROTR(a,13) ^ ROTR(a,22);
        UINT32 maj = (a & b) ^ (a & c) ^ (b & c);
        t2 = S0 + maj;
        h=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2;
    }
    ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d;
    ctx->state[4]+=e; ctx->state[5]+=f; ctx->state[6]+=g; ctx->state[7]+=h;
}
static void sha256Init(SHA256_CTX *ctx) {
    ctx->dataLength = 0; ctx->bitLength = 0;
    ctx->state[0]=0x6a09e667; ctx->state[1]=0xbb67ae85; ctx->state[2]=0x3c6ef372; ctx->state[3]=0xa54ff53a;
    ctx->state[4]=0x510e527f; ctx->state[5]=0x9b05688c; ctx->state[6]=0x1f83d9ab; ctx->state[7]=0x5be0cd19;
}
static void sha256Update(SHA256_CTX *ctx, const UINT8 data[], UINTN length) {
    for (UINTN i = 0; i < length; i++) {
        ctx->data[ctx->dataLength] = data[i];
        ctx->dataLength++;
        if (ctx->dataLength == 64) { sha256Transform(ctx, ctx->data); ctx->bitLength += 512; ctx->dataLength = 0; }
    }
}
static void sha256Final(SHA256_CTX *ctx, UINT8 hash[]) {
    UINT32 i = ctx->dataLength;
    ctx->data[i++] = 0x80;
    if (ctx->dataLength < 56) { while (i < 56) ctx->data[i++] = 0x00; }
    else { while (i < 64) ctx->data[i++] = 0x00; sha256Transform(ctx, ctx->data); for (int j = 0; j < 56; j++) ctx->data[j] = 0; }
    ctx->bitLength += ctx->dataLength * 8;
    ctx->data[63] = (UINT8)(ctx->bitLength);
    ctx->data[62] = (UINT8)(ctx->bitLength >> 8);
    ctx->data[61] = (UINT8)(ctx->bitLength >> 16);
    ctx->data[60] = (UINT8)(ctx->bitLength >> 24);
    ctx->data[59] = (UINT8)(ctx->bitLength >> 32);
    ctx->data[58] = (UINT8)(ctx->bitLength >> 40);
    ctx->data[57] = (UINT8)(ctx->bitLength >> 48);
    ctx->data[56] = (UINT8)(ctx->bitLength >> 56);
    sha256Transform(ctx, ctx->data);
    for (int a = 0; a < 8; a++) for (int b = 0; b < 4; b++) hash[a*4+b] = (UINT8)((ctx->state[a] >> (24 - b*8)) & 0xFF);
}
// Authenticode ハッシュ（ファームウェア側 Swift 実装と同一規則）
static int authenticodeHash(const UINT8 *data, UINTN size, UINT8 out[32]) {
    if (size <= 0x40 || data[0] != 0x4D || data[1] != 0x5A) return 0;
    UINT32 peOffset = (UINT32)data[0x3C] | ((UINT32)data[0x3D] << 8) | ((UINT32)data[0x3E] << 16) | ((UINT32)data[0x3F] << 24);
    if (peOffset == 0 || (UINT64)peOffset + 24 + 112 + 40 > size) return 0;
    UINTN optional = peOffset + 24;
    UINT16 magic = (UINT16)data[optional] | ((UINT16)data[optional+1] << 8);
    if (magic != 0x20B) return 0;
    UINTN checksumOffset = optional + 64;
    UINTN certEntryOffset = optional + 112 + 4 * 8;
    UINT32 numDirs = (UINT32)data[optional+108] | ((UINT32)data[optional+109] << 8) | ((UINT32)data[optional+110] << 16) | ((UINT32)data[optional+111] << 24);
    if (numDirs <= 4) return 0;
    UINT32 certSize = (UINT32)data[certEntryOffset+4] | ((UINT32)data[certEntryOffset+5] << 8) | ((UINT32)data[certEntryOffset+6] << 16) | ((UINT32)data[certEntryOffset+7] << 24);
    UINTN end = certSize > 0 ? size - certSize : size;
    if (end < certEntryOffset + 8 || end > size) return 0;
    SHA256_CTX ctx; sha256Init(&ctx);
    sha256Update(&ctx, data, checksumOffset);
    sha256Update(&ctx, data + checksumOffset + 4, certEntryOffset - (checksumOffset + 4));
    sha256Update(&ctx, data + certEntryOffset + 8, end - (certEntryOffset + 8));
    sha256Final(&ctx, out);
    return 1;
}

static volatile UINT32 ebsGroupFlag = 0;
__attribute__((ms_abi)) static void ebsGroupFn(EFI_EVENT event, VOID *context) {
    *(volatile UINT32 *)context = 1;
}
static int waitFlag(volatile UINT32 *flag, UINT32 value) {
    for (int t = 0; t < 200; t++) {
        if (*flag == value) return 1;
        for (volatile int i = 0; i < 50000; i++) { }
    }
    return *flag == value;
}

static UINT8 mapBuffer[8192];
static UINT8 tampered[8192];
static __int128 cxCell __attribute__((aligned(16)));

static void fillGuidBytes(UINT8 *dst, EFI_GUID *guid) {
    // EFI_GUID のメモリ表現はそのまま署名リストへコピーできる
    const UINT8 *src = (const UINT8 *)guid;
    for (int i = 0; i < 16; i++) dst[i] = src[i];
}
// 署名リスト（SHA-256 ハッシュ×count）を構築する
static UINTN buildSigList(UINT8 *out, const UINT8 hashes[][32], int count) {
    fillGuidBytes(out, &guidCertSHA256);
    UINT32 listSize = 28 + (UINT32)count * 48;
    out[16] = (UINT8)listSize; out[17] = (UINT8)(listSize >> 8); out[18] = 0; out[19] = 0;
    out[20] = 0; out[21] = 0; out[22] = 0; out[23] = 0; // HeaderSize
    out[24] = 48; out[25] = 0; out[26] = 0; out[27] = 0; // SignatureSize
    for (int e = 0; e < count; e++) {
        UINT8 *entry = out + 28 + e * 48;
        for (int i = 0; i < 16; i++) entry[i] = 0; // owner GUID
        for (int i = 0; i < 32; i++) entry[16 + i] = hashes[e][i];
    }
    return listSize;
}

EFI_STATUS EfiMain(EFI_HANDLE ImageHandle, EFI_SYSTEM_TABLE *SystemTable) {
    gST = SystemTable;
    EFI_BOOT_SERVICES *bs = SystemTable->BootServices;
    EFI_RUNTIME_SERVICES *rs = SystemTable->RuntimeServices;
    EFI_STATUS status;
    EFI_ALLOCATE_PAGES allocatePages = (EFI_ALLOCATE_PAGES)bs->AllocatePages;
    EFI_FREE_PAGES freePages = (EFI_FREE_PAGES)bs->FreePages;
    EFI_FREE_POOL freePool = (EFI_FREE_POOL)bs->FreePool;

    // ===== 1. アロケータ =====
    {
        UINT64 addr = 0;
        int ok = 1;
        status = allocatePages(0, 2, 4, &addr); // AnyPages
        if (status != EFI_SUCCESS || addr == 0 || (addr & 0xFFF) != 0) ok = 0;
        UINT64 same = addr;
        status = allocatePages(2, 2, 4, &same); // AllocateAddress（使用中）
        if (status != EFI_NOT_FOUND) ok = 0;
        status = freePages(addr, 4);
        if (status != EFI_SUCCESS) ok = 0;
        status = allocatePages(2, 2, 4, &addr); // 解放済みアドレスを再取得
        if (status != EFI_SUCCESS || addr != same) ok = 0;
        status = freePages(addr, 3); // ページ数不一致
        if (status != EFI_INVALID_PARAMETER) ok = 0;
        status = freePages(addr, 4);
        if (status != EFI_SUCCESS) ok = 0;
        UINT64 maxAddr = 0x600000;
        status = allocatePages(1, 2, 4, &maxAddr); // MaxAddress
        if (status != EFI_SUCCESS || maxAddr + 4 * 4096 > 0x600000) ok = 0;
        if (status == EFI_SUCCESS) freePages(maxAddr, 4);
        VOID *p1 = 0, *p2 = 0;
        status = bs->AllocatePool(4, 100, &p1);
        if (status != EFI_SUCCESS || !p1) ok = 0;
        freePool(p1);
        status = bs->AllocatePool(4, 100, &p2);
        if (status != EFI_SUCCESS || p2 != p1) ok = 0; // フリーリスト再利用
        freePool(p2);
        status = freePool(p2); // 二重解放
        if (status != EFI_INVALID_PARAMETER) ok = 0;
        print(ok ? "ALLOC OK" : "ALLOC NG");
        if (!ok) return 1;
    }

    // ===== 2. GOP 追加モード =====
    {
        EFI_GRAPHICS_OUTPUT_PROTOCOL *gop = 0;
        status = bs->LocateProtocol(&guidGOP, 0, (VOID **)&gop);
        int ok = status == EFI_SUCCESS && gop && gop->Mode && gop->Mode->MaxMode == 2;
        UINTN infoSize = 0;
        EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *info = 0;
        if (ok) {
            status = gop->QueryMode(gop, 1, &infoSize, &info);
            ok = status == EFI_SUCCESS && info && info->HorizontalResolution == 800 && info->VerticalResolution == 600;
        }
        if (ok) {
            status = gop->SetMode(gop, 1);
            ok = status == EFI_SUCCESS && gop->Mode->Mode == 1
                 && gop->Mode->FrameBufferSize == (UINTN)800 * 600 * 4;
        }
        if (ok) {
            volatile UINT32 *fb = (volatile UINT32 *)(UINTN)gop->Mode->FrameBufferBase;
            fb[0] = 0xFF112233;
            ok = fb[0] == 0xFF112233;
        }
        if (ok) {
            status = gop->QueryMode(gop, 3, &infoSize, &info);
            ok = status == EFI_INVALID_PARAMETER;
        }
        gop->SetMode(gop, 0);
        print(ok ? "GOP5 OK" : "GOP5 NG");
        if (!ok) return 1;
    }

    // ===== 3. CMPXCHG16B =====
    {
        __int128 initial = ((__int128)200 << 64) | (unsigned long long)100;
        __int128 updated = ((__int128)400 << 64) | (unsigned long long)300;
        cxCell = initial;
        __int128 prev = __sync_val_compare_and_swap(&cxCell, initial, updated);
        int ok = prev == initial && cxCell == updated;
        __int128 prev2 = __sync_val_compare_and_swap(&cxCell, initial, initial);
        ok = ok && prev2 == updated && cxCell == updated;
        print(ok ? "CX16 OK" : "CX16 NG");
        if (!ok) return 1;
    }

    // ===== 4. Secure Boot =====
    {
        int ok = 1;
        UINT8 value = 0xFF;
        UINTN valueSize = 1;
        static CHAR16 nameSecureBoot[] = {'S','e','c','u','r','e','B','o','o','t',0};
        static CHAR16 nameSetupMode[] = {'S','e','t','u','p','M','o','d','e',0};
        static CHAR16 nameDB[] = {'d','b',0};
        static CHAR16 nameDBX[] = {'d','b','x',0};
        static CHAR16 namePK[] = {'P','K',0};
        status = rs->GetVariable(nameSecureBoot, &guidGlobal, 0, &valueSize, &value);
        if (status != EFI_SUCCESS || value != 0) ok = 0;
        value = 0; valueSize = 1;
        status = rs->GetVariable(nameSetupMode, &guidGlobal, 0, &valueSize, &value);
        if (status != EFI_SUCCESS || value != 1) ok = 0;
        // 子イメージと改竄イメージのハッシュ
        UINT8 childHash[32], tamperedHash[32];
        if (!authenticodeHash(child_image, child_image_size, childHash)) ok = 0;
        for (UINTN i = 0; i < child_image_size; i++) tampered[i] = child_image[i];
        tampered[0x200] ^= 0xFF;
        if (!authenticodeHash(tampered, child_image_size, tamperedHash)) ok = 0;
        // db: 子 + 改竄の両方、dbx: 改竄のみ（dbx 優先の確認）
        static UINT8 dbData[28 + 48 * 2];
        static UINT8 dbxData[28 + 48];
        static UINT8 dbHashes[2][32];
        static UINT8 dbxHashes[1][32];
        for (int i = 0; i < 32; i++) { dbHashes[0][i] = childHash[i]; dbHashes[1][i] = tamperedHash[i]; dbxHashes[0][i] = tamperedHash[i]; }
        UINTN dbSize = buildSigList(dbData, (const UINT8 (*)[32])dbHashes, 2);
        UINTN dbxSize = buildSigList(dbxData, (const UINT8 (*)[32])dbxHashes, 1);
        status = rs->SetVariable(nameDB, &guidSecurityDB, 0x3, dbSize, dbData);
        if (status != EFI_SUCCESS) ok = 0;
        status = rs->SetVariable(nameDBX, &guidSecurityDB, 0x3, dbxSize, dbxData);
        if (status != EFI_SUCCESS) ok = 0;
        UINT8 pkByte = 1;
        status = rs->SetVariable(namePK, &guidGlobal, 0x3, 1, &pkByte);
        if (status != EFI_SUCCESS) ok = 0;
        print(ok ? "SBSETUP OK" : "SBSETUP NG");
        if (!ok) return 1;
        // db を読み戻して内容を検証する
        {
            static UINT8 readback[256];
            UINTN rbSize = sizeof(readback);
            EFI_STATUS rbStatus = rs->GetVariable(nameDB, &guidSecurityDB, 0, &rbSize, readback);
            int rbOk = rbStatus == EFI_SUCCESS && rbSize == dbSize;
            if (rbOk) for (UINTN i = 0; i < dbSize; i++) if (readback[i] != dbData[i]) { rbOk = 0; break; }
            print(rbOk ? "DBREAD OK" : "DBREAD NG");
            if (!rbOk) return 1;
        }
        // ユーザーモードへ移行したこと
        value = 0; valueSize = 1;
        status = rs->GetVariable(nameSecureBoot, &guidGlobal, 0, &valueSize, &value);
        ok = status == EFI_SUCCESS && value == 1;
        value = 1; valueSize = 1;
        status = rs->GetVariable(nameSetupMode, &guidGlobal, 0, &valueSize, &value);
        ok = ok && status == EFI_SUCCESS && value == 0;
        // 正規の子イメージはロードできる
        EFI_HANDLE childHandle = 0;
        status = bs->LoadImage(0, ImageHandle, 0, (VOID *)child_image, child_image_size, &childHandle);
        ok = ok && status == EFI_SUCCESS && childHandle != 0;
        if (childHandle) { bs->UnloadImage(childHandle); childHandle = 0; }
        print(ok ? "SBLOAD OK" : "SBLOAD NG");
        if (!ok) return 1;
        // 改竄イメージは db にあるが dbx にもあるので拒否される
        status = bs->LoadImage(0, ImageHandle, 0, (VOID *)tampered, child_image_size, &childHandle);
        print(status == EFI_SECURITY_VIOLATION ? "SBDBX OK" : "SBDBX NG");
        if (status != EFI_SECURITY_VIOLATION) return 1;
        // db に無いハッシュ（別のバイトも改竄）も拒否される
        tampered[0x201] ^= 0xFF;
        status = bs->LoadImage(0, ImageHandle, 0, (VOID *)tampered, child_image_size, &childHandle);
        print(status == EFI_SECURITY_VIOLATION ? "SBDB OK" : "SBDB NG");
        if (status != EFI_SECURITY_VIOLATION) return 1;
        // ユーザーモードでは db を更新できない
        status = rs->SetVariable(nameDB, &guidSecurityDB, 0x3, dbSize, dbData);
        print(status == EFI_SECURITY_VIOLATION ? "SBLOCK OK" : "SBLOCK NG");
        if (status != EFI_SECURITY_VIOLATION) return 1;
    }

    // ===== 5. ページテーブル用メモリ（EBS 前に確保） =====
    UINT64 tablePages = 0;
    status = allocatePages(0, 2, 3, &tablePages);
    if (status != EFI_SUCCESS) { print("VAC NG (tables)"); return 1; }
    {
        UINT8 *pages = (UINT8 *)(UINTN)tablePages;
        for (int i = 0; i < 3 * 4096; i++) pages[i] = 0;
        UINT64 *pml4 = (UINT64 *)(UINTN)tablePages;
        UINT64 *pdpt = (UINT64 *)(UINTN)(tablePages + 0x1000);
        UINT64 *pd = (UINT64 *)(UINTN)(tablePages + 0x2000);
        pml4[0] = (tablePages + 0x1000) | 3;
        pdpt[0] = (tablePages + 0x2000) | 3;
        for (int i = 0; i < 8; i++) pd[i] = ((UINT64)i * 0x200000) | 0x83; // 0–16MiB identity (2MiB pages)
        pd[16] = 0x200000 | 0x83; // 仮想 0x2000000 → 物理 0x200000（ランタイム領域のエイリアス）
    }

    // ===== 6. CreateEventEx（EBS グループ）+ EBS =====
    UINTN mapSize = 0, mapKey = 0, descriptorSize = 0;
    {
        EFI_EVENT event = 0;
        EFI_CREATE_EVENT_EX createEventEx = (EFI_CREATE_EVENT_EX)bs->CreateEventEx;
        status = createEventEx(0x200, 0, (VOID *)ebsGroupFn, (VOID *)&ebsGroupFlag, &guidEBSGroup, &event);
        if (status != EFI_SUCCESS) { print("EBSEX NG (create)"); return 1; }
        mapSize = sizeof(mapBuffer);
        UINT32 descriptorVersion = 0;
        status = bs->GetMemoryMap(&mapSize, mapBuffer, &mapKey, &descriptorSize, &descriptorVersion);
        if (status != EFI_SUCCESS) { print("EBSEX NG (map)"); return 1; }
        status = bs->ExitBootServices(ImageHandle, mapKey);
        if (status != EFI_SUCCESS) { print("EBSEX NG (ebs)"); return 1; }
        print(waitFlag(&ebsGroupFlag, 1) ? "EBSEX OK" : "EBSEX NG");
    }

    // ===== 7. SetVirtualAddressMap =====
    {
        const UINT64 DELTA = 0x1E00000;
        int runtimeCount = 0;
        for (UINTN offset = 0; offset + descriptorSize <= mapSize; offset += descriptorSize) {
            UINT8 *desc = mapBuffer + offset;
            UINT64 attribute = 0;
            for (int i = 0; i < 8; i++) attribute |= (UINT64)desc[32 + i] << (8 * i);
            if (attribute & 0x8000000000000000ULL) {
                UINT64 physical = 0;
                for (int i = 0; i < 8; i++) physical |= (UINT64)desc[8 + i] << (8 * i);
                UINT64 virtualAddr = physical + DELTA;
                for (int i = 0; i < 8; i++) desc[16 + i] = (UINT8)(virtualAddr >> (8 * i));
                runtimeCount++;
            }
        }
        if (runtimeCount == 0) { print("VAC NG (no runtime)"); return 1; }
        EFI_SET_VIRTUAL_ADDRESS_MAP setVAM = (EFI_SET_VIRTUAL_ADDRESS_MAP)rs->SetVirtualAddressMap;
        status = setVAM(mapSize, descriptorSize, 1, mapBuffer);
        if (status != EFI_SUCCESS) { print("VAC NG (setvam)"); return 1; }
        __asm__ volatile("movq %0, %%cr3" :: "r"(tablePages) : "memory");
        // ConvertPointer の確認
        VOID *pointer = (VOID *)(UINTN)0x300600;
        EFI_CONVERT_POINTER convertPointer = (EFI_CONVERT_POINTER)rs->ConvertPointer;
        status = convertPointer(0, &pointer);
        if (status != EFI_SUCCESS || pointer != (VOID *)(UINTN)(0x300600 + DELTA)) { print("VAC NG (convert)"); return 1; }
        // 変換済みポインタ経由で GetTime を呼ぶ（テーブルも関数ポインタも仮想アドレスへ変換）
        EFI_RUNTIME_SERVICES *virtualRS = (EFI_RUNTIME_SERVICES *)(UINTN)((UINT64)(UINTN)rs + DELTA);
        EFI_GET_TIME virtualGetTime = (EFI_GET_TIME)(UINTN)((UINT64)(UINTN)virtualRS->GetTime + DELTA);
        EFI_TIME time;
        status = virtualGetTime(&time, 0);
        int ok = status == EFI_SUCCESS && time.Year >= 2020 && time.Year <= 2100;
        print(ok ? "VAC OK" : "VAC NG");
        if (!ok) return 1;
    }

    print("UEFI5 DONE");
    return 0;
}
