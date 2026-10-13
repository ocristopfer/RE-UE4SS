#define NOMINMAX

#include <filesystem>
#ifdef _WIN32
#include <Windows.h>
#else
#include <dlfcn.h>
#endif

#include <DynamicOutput/DynamicOutput.hpp>
#include <Helpers/SysError.hpp>
#include <Helpers/String.hpp>
#include <Mod/CppMod.hpp>

namespace RC
{
    CppMod::CppMod(UE4SSProgram& program, StringType&& mod_name, StringType&& mod_path) : Mod(program, std::move(mod_name), std::move(mod_path))
    {
        m_dlls_path = m_mod_path / STR("dlls");

        if (!std::filesystem::exists(m_dlls_path))
        {
            Output::send<LogLevel::Warning>(STR("Could not find the dlls folder for mod {}\n"), m_mod_name);
            set_installable(false);
            return;
        }

#ifdef _WIN32
        constexpr auto library_extension = STR("dll");
#else
        // Same layout on Linux, with a shared object: dlls/main.so or dlls/<mod name>.so.
        constexpr auto library_extension = STR("so");
#endif
        auto dll_path = m_dlls_path / fmt::format(STR("main.{}"), library_extension);
        if (!std::filesystem::exists(dll_path))
        {
            dll_path = m_dlls_path / fmt::format(STR("{}.{}"), mod_name, library_extension);

            if (!std::filesystem::exists(dll_path))
            {
                Output::send<LogLevel::Warning>(STR("Failed to load C++ mod {}, dlls folder must contain either main.{} or {}\n"),
                                                m_mod_name, library_extension, ensure_str(dll_path.filename()));
                set_installable(false);
                return;
            }
        }

        m_dll_filename = ensure_str(dll_path.filename());

#ifdef _WIN32
        // Add mods dlls directory to search path for dynamic/shared linked libraries in mods
        m_dlls_path_cookie = AddDllDirectory(m_dlls_path.c_str());
        m_main_dll_module = LoadLibraryExW(dll_path.c_str(), NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);

        if (!m_main_dll_module)
        {
            Output::send<LogLevel::Warning>(STR("Failed to load dll <{}> for mod {}, error: {}\n"),
                                            ensure_str(dll_path), m_mod_name, SysError(GetLastError()).c_str());
            set_installable(false);
            return;
        }

        m_start_mod_func = reinterpret_cast<start_type>(GetProcAddress(m_main_dll_module, "start_mod"));
        m_uninstall_mod_func = reinterpret_cast<uninstall_type>(GetProcAddress(m_main_dll_module, "uninstall_mod"));
#else
        // RTLD_LOCAL: two mods may export the same symbol names (start_mod/uninstall_mod).
        m_main_dll_module = dlopen(dll_path.c_str(), RTLD_NOW | RTLD_LOCAL);

        if (!m_main_dll_module)
        {
            const char* error = dlerror();
            Output::send<LogLevel::Warning>(STR("Failed to load shared object <{}> for mod {}, error: {}\n"),
                                            ensure_str(dll_path), m_mod_name, ensure_str(error ? error : "unknown"));
            set_installable(false);
            return;
        }

        m_start_mod_func = reinterpret_cast<start_type>(dlsym(m_main_dll_module, "start_mod"));
        m_uninstall_mod_func = reinterpret_cast<uninstall_type>(dlsym(m_main_dll_module, "uninstall_mod"));
#endif

        if (!m_start_mod_func || !m_uninstall_mod_func)
        {
            Output::send<LogLevel::Warning>(STR("Failed to find exported mod lifecycle functions for mod {}\n"), m_mod_name);

#ifdef _WIN32
            FreeLibrary(m_main_dll_module);
            m_main_dll_module = NULL;
#else
            dlclose(m_main_dll_module);
            m_main_dll_module = nullptr;
#endif

            set_installable(false);
            return;
        }
    }

    auto CppMod::start_mod() -> void
    {
        try
        {
            m_mod = m_start_mod_func();
            m_is_started = m_mod != nullptr;
        }
        catch (std::exception& e)
        {
            if (!Output::has_internal_error())
            {
                Output::send<LogLevel::Warning>(STR("Failed to load dll <{}> for mod {}, because: {}\n"),
                                                ensure_str((m_dlls_path / m_dll_filename)),
                                                m_mod_name,
                                                ensure_str(e.what()));
            }
            else
            {
                printf_s("Internal Error: %s\n", e.what());
            }
        }
    }

    auto CppMod::uninstall() -> void
    {
        Output::send(STR("Stopping C++ mod '{}' for uninstall\n"), m_mod_name);
        if (m_mod && m_uninstall_mod_func)
        {
            m_uninstall_mod_func(m_mod);
        }
    }

    auto CppMod::fire_on_lua_start(StringViewType mod_name,
                                   LuaMadeSimple::Lua& lua,
                                   LuaMadeSimple::Lua& main_lua,
                                   LuaMadeSimple::Lua& async_lua,
                                   LuaMadeSimple::Lua* hook_lua) -> void
    {
        if (m_mod)
        {
            // Call new API
            m_mod->on_lua_start(mod_name, lua, main_lua, async_lua, hook_lua);

            // Call old deprecated API for backwards compatibility
            std::vector<LuaMadeSimple::Lua*> hook_luas;
            if (hook_lua)
            {
                hook_luas.push_back(hook_lua);
            }
            m_mod->on_lua_start(mod_name, lua, main_lua, async_lua, hook_luas);
        }
    }

    auto CppMod::fire_on_lua_start(LuaMadeSimple::Lua& lua,
                                   LuaMadeSimple::Lua& main_lua,
                                   LuaMadeSimple::Lua& async_lua,
                                   LuaMadeSimple::Lua* hook_lua) -> void
    {
        if (m_mod)
        {
            // Call new API
            m_mod->on_lua_start(lua, main_lua, async_lua, hook_lua);

            // Call old deprecated API for backwards compatibility
            std::vector<LuaMadeSimple::Lua*> hook_luas;
            if (hook_lua)
            {
                hook_luas.push_back(hook_lua);
            }
            m_mod->on_lua_start(lua, main_lua, async_lua, hook_luas);
        }
    }

    auto CppMod::fire_on_lua_stop(StringViewType mod_name,
                                  LuaMadeSimple::Lua& lua,
                                  LuaMadeSimple::Lua& main_lua,
                                  LuaMadeSimple::Lua& async_lua,
                                  LuaMadeSimple::Lua* hook_lua) -> void
    {
        if (m_mod)
        {
            // Call new API
            m_mod->on_lua_stop(mod_name, lua, main_lua, async_lua, hook_lua);

            // Call old deprecated API for backwards compatibility
            std::vector<LuaMadeSimple::Lua*> hook_luas;
            if (hook_lua)
            {
                hook_luas.push_back(hook_lua);
            }
            m_mod->on_lua_stop(mod_name, lua, main_lua, async_lua, hook_luas);
        }
    }

    auto CppMod::fire_on_lua_stop(LuaMadeSimple::Lua& lua, LuaMadeSimple::Lua& main_lua, LuaMadeSimple::Lua& async_lua, LuaMadeSimple::Lua* hook_lua) -> void
    {
        if (m_mod)
        {
            // Call new API
            m_mod->on_lua_stop(lua, main_lua, async_lua, hook_lua);

            // Call old deprecated API for backwards compatibility
            std::vector<LuaMadeSimple::Lua*> hook_luas;
            if (hook_lua)
            {
                hook_luas.push_back(hook_lua);
            }
            m_mod->on_lua_stop(lua, main_lua, async_lua, hook_luas);
        }
    }

    auto CppMod::fire_unreal_init() -> void
    {
        if (m_mod)
        {
            m_mod->on_unreal_init();
        }
    }

    auto CppMod::fire_ui_init() -> void
    {
        if (m_mod)
        {
            m_mod->on_ui_init();
        }
    }

    auto CppMod::fire_program_start() -> void
    {
        if (m_mod)
        {
            m_mod->on_program_start();
        }
    }

    auto CppMod::fire_update() -> void
    {
        if (m_mod)
        {
            m_mod->on_update();
        }
    }

    auto CppMod::fire_dll_load(StringViewType dll_name) -> void
    {
        if (m_mod)
        {
            m_mod->on_dll_load(dll_name);
        }
    }

    auto CppMod::fire_on_cpp_mods_loaded() -> void
    {
        if (m_mod)
        {
            m_mod->on_cpp_mods_loaded();
        }
    }

    auto CppMod::get_user_mod() -> CppUserModBase*
    {
        return m_mod;
    }

    CppMod::~CppMod()
    {
        if (m_main_dll_module)
        {
#ifdef _WIN32
            FreeLibrary(m_main_dll_module);
            RemoveDllDirectory(m_dlls_path_cookie);
#else
            dlclose(m_main_dll_module);
#endif
        }
    }
} // namespace RC
