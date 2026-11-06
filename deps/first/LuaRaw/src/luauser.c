#ifdef _WIN32
#include <windows.h>
#else
#include <pthread.h>
#endif
#include "lua.h"

#ifdef _WIN32
static struct {
    CRITICAL_SECTION LockSct;
    BOOL Init;
} Gl;

void LuaLockInitial(lua_State* L)
{
    if (!Gl.Init)
    {
        /* Create a mutex */
        InitializeCriticalSection(&Gl.LockSct);
        Gl.Init = TRUE;
    }
}

void LuaLock(lua_State* L)
{
    LuaLockInitial(L);
    /* Wait for control of mutex */
    EnterCriticalSection(&Gl.LockSct);
}

void LuaUnlock(lua_State* L)
{
    /* Release control of mutex */
    LeaveCriticalSection(&Gl.LockSct);
}
#else
/* A CRITICAL_SECTION may be re-entered by the thread that holds it: the recursive mutex is the
   same contract (Lua takes the lock again from inside calls that already hold it). */
static struct {
    pthread_mutex_t Lock;
    int Init;
} Gl;

void LuaLockInitial(lua_State* L)
{
    if (!Gl.Init)
    {
        pthread_mutexattr_t Attr;
        pthread_mutexattr_init(&Attr);
        pthread_mutexattr_settype(&Attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&Gl.Lock, &Attr);
        pthread_mutexattr_destroy(&Attr);
        Gl.Init = 1;
    }
}

void LuaLockFinal(lua_State* L)
{
    if (Gl.Init)
    {
        pthread_mutex_destroy(&Gl.Lock);
        Gl.Init = 0;
    }
}

void LuaLock(lua_State* L)
{
    LuaLockInitial(L);
    pthread_mutex_lock(&Gl.Lock);
}

void LuaUnlock(lua_State* L)
{
    pthread_mutex_unlock(&Gl.Lock);
}
#endif
