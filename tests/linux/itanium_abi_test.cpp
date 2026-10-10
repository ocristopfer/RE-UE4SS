// The Itanium ABI rules of the Linux port (Unreal/ItaniumAbi.hpp), without a game: the vtable shift
// that the MSVC-generated layouts need, and the ProcessLocalScriptFunction tail-jump search.
#include <cstdio>
#include <cstdint>
#include <unordered_map>

#include <Unreal/ItaniumAbi.hpp>

using namespace RC;
using namespace RC::Unreal;

static int Failures{};

#define CHECK(cond)                                                                                                                                            \
    do                                                                                                                                                         \
    {                                                                                                                                                          \
        if (!(cond))                                                                                                                                           \
        {                                                                                                                                                      \
            std::fprintf(stderr, "%s:%d: CHECK(%s) failed\n", __FILE__, __LINE__, #cond);                                                                      \
            ++Failures;                                                                                                                                        \
        }                                                                                                                                                      \
    } while (0)

using Map = std::unordered_map<StringType, uint32_t>;
constexpr uint32_t Slot = sizeof(void*);

static auto ShiftsEverythingAfterTheDestructor() -> void
{
    Map M{{STR("__vecDelDtor"), 0}, {STR("A"), Slot}, {STR("B"), 2 * Slot}};
    ItaniumAbi::ShiftForItanium(M, {});
    CHECK(M[STR("__vecDelDtor")] == 0);
    CHECK(M[STR("A")] == 2 * Slot);
    CHECK(M[STR("B")] == 3 * Slot);
    // Nothing came from an ini: the class is still not known, so its vtable hooks stay off.
    CHECK(!ItaniumAbi::IsLayoutKnown(M));
}

static auto LeavesWhatComesBeforeTheDestructor() -> void
{
    // FField has its destructor at 0x8.
    Map M{{STR("X"), 0}, {STR("__vecDelDtor"), Slot}, {STR("Y"), 2 * Slot}};
    ItaniumAbi::ShiftForItanium(M, {});
    CHECK(M[STR("X")] == 0);
    CHECK(M[STR("__vecDelDtor")] == Slot);
    CHECK(M[STR("Y")] == 3 * Slot);
}

static auto LeavesLinuxLayoutsAlone() -> void
{
    Map M{{STR("__itanium_layout"), 0}, {STR("__vecDelDtor"), 0}, {STR("A"), Slot}};
    ItaniumAbi::ShiftForItanium(M, {});
    CHECK(M[STR("A")] == Slot);
    CHECK(ItaniumAbi::IsLayoutKnown(M));
}

static auto LeavesMapsWithoutDestructorAlone() -> void
{
    Map M{{STR("A"), 0}, {STR("B"), Slot}};
    ItaniumAbi::ShiftForItanium(M, {});
    CHECK(M[STR("A")] == 0);
    CHECK(M[STR("B")] == Slot);
}

static auto IniEntriesKeepTheirOffsetsAndMakeTheClassKnown() -> void
{
    Map M{{STR("__vecDelDtor"), 0}, {STR("A"), Slot}, {STR("FromIni"), 7 * Slot}};
    const auto Given = ItaniumAbi::KeysOf(Map{{STR("FromIni"), 7 * Slot}});
    ItaniumAbi::ShiftForItanium(M, Given);
    CHECK(M[STR("A")] == 2 * Slot);
    CHECK(M[STR("FromIni")] == 7 * Slot);
    CHECK(ItaniumAbi::IsLayoutKnown(M));
}

static auto FindsTheTailJumpPastTheFirstRet() -> void
{
    // 0: jmp short +0 (to 2, before the ret)  2: jmp near +10 (to 17, past the ret)  7: ret
    const uint8_t Code[] = {0xEB, 0x00, 0xE9, 0x0A, 0x00, 0x00, 0x00, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC};
    constexpr uint64_t Base = 0x10000;
    CHECK(ItaniumAbi::FindTailJumpPastFirstRet(Code, sizeof(Code), Base) == Base + 17);
}

static auto IgnoresJumpsThatStayBeforeTheRet() -> void
{
    // 0: test rax,rax  3: jmp short +1 (to 6)  5: nop  6: ret  7: jmp near (after the ret: not looked at)
    const uint8_t Code[] = {0x48, 0x85, 0xC0, 0xEB, 0x01, 0x90, 0xC3, 0xE9, 0x10, 0x00, 0x00, 0x00};
    CHECK(ItaniumAbi::FindTailJumpPastFirstRet(Code, sizeof(Code), 0x20000) == 0);
}

static auto NeedsARet() -> void
{
    // A jump forward without any ret in the window is not the tail call.
    const uint8_t Code[] = {0xE9, 0x10, 0x00, 0x00, 0x00, 0x90, 0x90};
    CHECK(ItaniumAbi::FindTailJumpPastFirstRet(Code, sizeof(Code), 0x30000) == 0);
}

int main()
{
    ShiftsEverythingAfterTheDestructor();
    LeavesWhatComesBeforeTheDestructor();
    LeavesLinuxLayoutsAlone();
    LeavesMapsWithoutDestructorAlone();
    IniEntriesKeepTheirOffsetsAndMakeTheClassKnown();
    FindsTheTailJumpPastTheFirstRet();
    IgnoresJumpsThatStayBeforeTheRet();
    NeedsARet();
    if (Failures) { std::fprintf(stderr, "%d check(s) failed\n", Failures); }
    return Failures ? 1 : 0;
}
