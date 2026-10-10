// The signature scanner on Linux, over this test's own executable: the module range comes from
// dl_iterate_phdr like UnrealInitializer's, and it spans the holes between PT_LOAD segments, which
// the scanner must skip through its /proc/self/maps regions instead of reading them.
#include <cstdio>
#include <cstdint>
#include <link.h>

#include <SigScanner/SinglePassSigScanner.hpp>

using namespace RC;

// Bytes that exist once in the image: the scanner must find them here, and only here.
extern "C" __attribute__((used)) const uint8_t UE4SS_SelfScan_Needle[] = {0x5A, 0xC3, 0x9E, 0x11, 0x77, 0x42, 0xE1, 0x0D,
                                                                          0xB8, 0x6F, 0x23, 0x91, 0x4C, 0xA7, 0x3B, 0xD5};

static auto MainExecutable() -> OS_MODULEINFO
{
    OS_MODULEINFO Info{};
    dl_iterate_phdr(
            [](dl_phdr_info* Phdr, size_t, void* Data) -> int {
                if (Phdr->dlpi_name && Phdr->dlpi_name[0] != '\0') { return 0; }
                auto& Out = *static_cast<OS_MODULEINFO*>(Data);
                uintptr_t Low = UINTPTR_MAX, High = 0;
                for (int Index = 0; Index < Phdr->dlpi_phnum; ++Index)
                {
                    const auto& Segment = Phdr->dlpi_phdr[Index];
                    if (Segment.p_type != PT_LOAD) { continue; }
                    Low = std::min<uintptr_t>(Low, Phdr->dlpi_addr + Segment.p_vaddr);
                    High = std::max<uintptr_t>(High, Phdr->dlpi_addr + Segment.p_vaddr + Segment.p_memsz);
                }
                Out.lpBaseOfDll = reinterpret_cast<void*>(Low);
                Out.SizeOfImage = static_cast<unsigned long>(High - Low);
                return 1;
            },
            &Info);
    return Info;
}

static auto Scan(SinglePassScanner::ScanMethod Method, const char* Signature, int& Matches) -> uint8_t*
{
    SinglePassScanner::m_scan_method = Method;
    uint8_t* Found{};
    Matches = 0;
    SinglePassScanner::SignatureContainerMap Containers;
    Containers[ScanTarget::MainExe].emplace_back(
            std::vector<SignatureData>{{Signature}},
            [&](SignatureContainer& Container) {
                Found = Container.get_match_address();
                ++Matches;
                return false;
            },
            [](SignatureContainer&) {});
    SinglePassScanner::start_scan(Containers);
    return Found;
}

int main()
{
    const auto Exe = MainExecutable();
    if (!Exe.lpBaseOfDll || !Exe.SizeOfImage)
    {
        std::fprintf(stderr, "main executable not found by dl_iterate_phdr\n");
        return 1;
    }
    for (size_t Index = 0; Index < static_cast<size_t>(ScanTarget::Max); ++Index)
    {
        SigScannerStaticData::m_modules_info.array[Index] = Exe;
    }
    SigScannerStaticData::m_is_modular = false;

    int Failures{};
    for (const auto Method : {SinglePassScanner::ScanMethod::Scalar, SinglePassScanner::ScanMethod::StdFind})
    {
        const char* Name = Method == SinglePassScanner::ScanMethod::Scalar ? "Scalar" : "StdFind";
        int Matches{};
        // Exact bytes, then with wildcards in the middle.
        for (const char* Signature : {"5A C3 9E 11 77 42 E1 0D B8 6F 23 91 4C A7 3B D5", "5A C3 9E 11 ?? ?? E1 0D B8 6F ?? 91 4C A7 3B D5"})
        {
            const auto Found = Scan(Method, Signature, Matches);
            if (Found != UE4SS_SelfScan_Needle || Matches != 1)
            {
                std::fprintf(stderr, "%s '%s': found %p (%d match(es)), expected %p once\n", Name, Signature, static_cast<void*>(Found), Matches,
                             static_cast<const void*>(UE4SS_SelfScan_Needle));
                ++Failures;
            }
        }
        // Bytes that are nowhere: the whole image is walked, holes included, without a crash.
        if (Scan(Method, "5A C3 9E 11 77 42 E1 0D B8 6F 23 91 4C A7 3B D6", Matches) || Matches)
        {
            std::fprintf(stderr, "%s: matched bytes that are not in the image\n", Name);
            ++Failures;
        }
    }
    return Failures ? 1 : 0;
}
