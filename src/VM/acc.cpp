#include <bridge.h>

#include "lobject.h"
#include "lstate.h"

ZIG_EXPORT const unsigned char GCObject_size = sizeof(GCObject);
ZIG_EXPORT const unsigned char GCheader_size = sizeof(GCheader);
ZIG_EXPORT const unsigned char Value_size = sizeof(Value);
ZIG_EXPORT const unsigned char TValue_size = sizeof(TValue);
ZIG_EXPORT const unsigned char TString_size = sizeof(TString);
ZIG_EXPORT const unsigned char Udata_size = sizeof(Udata);
ZIG_EXPORT const unsigned char LuauBuffer_size = sizeof(LuauBuffer);
ZIG_EXPORT const unsigned char Proto_size = sizeof(Proto);
ZIG_EXPORT const unsigned char LocVar_size = sizeof(LocVar);
ZIG_EXPORT const unsigned char UpVal_size = sizeof(UpVal);
ZIG_EXPORT const unsigned char Closure_size = sizeof(Closure);
ZIG_EXPORT const unsigned char TKey_size = sizeof(TKey);
ZIG_EXPORT const unsigned char LuaNode_size = sizeof(LuaNode);
ZIG_EXPORT const unsigned char LuaTable_size = sizeof(LuaTable);
ZIG_EXPORT const unsigned char LuauClass_size = sizeof(LuauClass);
ZIG_EXPORT const unsigned char LuauObject_size = sizeof(LuauObject);

ZIG_EXPORT const unsigned char TString_data_offset = offsetof(TString, data);
ZIG_EXPORT const unsigned char Udata_data_offset = offsetof(Udata, data);
ZIG_EXPORT const unsigned char LuauBuffer_data_offset = offsetof(LuauBuffer, data);