//! Wire every primitive into the global environment.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("../abi/mod.zig");
const Value = abi.Value;

const gc_mod = @import("../gc/collector.zig");
const GC = gc_mod.GC;

const runtime = @import("../runtime/mod.zig");
const objects = runtime.objects;
const SymbolTable = runtime.SymbolTable;
const GlobalEnv = runtime.GlobalEnv;

const vm_mod = @import("../vm/dispatch.zig");
const PrimFn = vm_mod.PrimFn;

const pairs = @import("pairs.zig");
const predicates = @import("predicates.zig");
const equality = @import("equality.zig");
const arith = @import("arith.zig");
const apply_mod = @import("apply.zig");
const io_mod = @import("io.zig");
const sys_mod = @import("sys.zig");
const tui_mod = @import("tui.zig");
const ffi_accessors = @import("../ffi/accessors.zig");
const ffi_json = @import("../ffi/json.zig");
const hashtable_prims = @import("hashtable.zig");
const time_prims = @import("time.zig");
const net_prims = @import("net.zig");
const http_prims = @import("http.zig");
const regex_prims = @import("regex.zig");
const math_prims = @import("math.zig");
const debug_prims = @import("debug.zig");
const bitwise_prims = @import("bitwise.zig"); // zepo-qny
const signal_prims = @import("signal.zig"); // zepo-6qx

const Entry = struct {
    name: []const u8,
    arity: i64, // -1 = variadic
    fn_ptr: PrimFn,
};

fn make(name: []const u8, arity: i64, f: PrimFn) Entry {
    return .{ .name = name, .arity = arity, .fn_ptr = f };
}

const TABLE: []const Entry = &.{
    make("cons", 2, pairs.primCons),
    make("car", 1, pairs.primCar),
    make("cdr", 1, pairs.primCdr),
    make("pair?", 1, pairs.primPairQ),
    make("null?", 1, pairs.primNullQ),

    make("symbol?", 1, predicates.primSymbolQ),
    make("boolean?", 1, predicates.primBooleanQ),
    make("number?", 1, predicates.primNumberQ),
    make("integer?", 1, predicates.primIntegerQ),
    make("float?", 1, predicates.primFloatQ),
    make("char?", 1, predicates.primCharQ),
    make("string?", 1, predicates.primStringQ),
    make("procedure?", 1, predicates.primProcedureQ),

    make("eq?", 2, equality.primEqQ),
    make("equal?", 2, equality.primEqualQ),

    make("+", -1, arith.primAdd),
    make("-", -1, arith.primSub),
    make("*", -1, arith.primMul),
    make("/", -1, arith.primDiv),
    make("=", -1, arith.primNumEq),
    make("<", -1, arith.primLt),
    make(">", -1, arith.primGt),
    make("<=", -1, arith.primLte),
    make(">=", -1, arith.primGte),

    make("not", 1, apply_mod.primNot),
    make("apply", -1, apply_mod.primApply),
    make("values", -1, apply_mod.primValues),
    make("call-with-values", 2, apply_mod.primCallWithValues),

    make("display", 1, io_mod.primDisplay),
    make("open-output-string", 0, io_mod.primOpenOutputString),
    make("string-port?", 1, io_mod.primStringPortQ),
    make("get-output-string", 1, io_mod.primGetOutputString),
    make("port-display", 2, io_mod.primPortDisplay),
    make("port-write", 2, io_mod.primPortWrite),
    make("newline", 0, io_mod.primNewline),

    make("list", -1, pairs.primList),
    make("vector", -1, pairs.primVector),
    make("make-vector", -1, pairs.primMakeVector),
    make("vector-ref", 2, pairs.primVectorRef),
    make("vector-set!", 3, pairs.primVectorSet),
    make("vector-length", 1, pairs.primVectorLength),
    make("vector?", 1, pairs.primVectorQ),
    make("vector-copy", -1, pairs.primVectorCopy),
    make("vector-copy!", -1, pairs.primVectorCopyBang),
    make("vector-fill!", -1, pairs.primVectorFillBang),
    make("vector-append", -1, pairs.primVectorAppend),
    make("string-length", 1, pairs.primStringLength),
    make("string-append", -1, pairs.primStringAppend),
    make("number->string", 1, pairs.primNumberToString),
    make("string-ref", 2, pairs.primStringRef),
    make("substring", -1, pairs.primSubstring),
    make("string->number", 1, pairs.primStringToNumber),
    make("symbol->string", 1, pairs.primSymbolToString),
    make("string->symbol", 1, pairs.primStringToSymbol),
    make("gensym", -1, pairs.primGensym), // zepo-voc: 0..1 args, arity checked in prim
    make("char->integer", 1, pairs.primCharToInteger),
    make("integer->char", 1, pairs.primIntegerToChar),
    make("getkey", 3, pairs.primGetkey),
    make("error", -1, pairs.primError),
    make("raise", 1, pairs.primRaise),
    make("with-exception-handler", 2, pairs.primWithExceptionHandler),
    make("error-object?", 1, pairs.primErrorObjectQ),
    make("error-object-message", 1, pairs.primErrorObjectMessage),
    make("error-object-irritants", 1, pairs.primErrorObjectIrritants),

    make("modulo", 2, arith.primModulo),
    make("remainder", 2, arith.primRemainder),
    make("quotient", 2, arith.primQuotient),
    make("floor", 1, arith.primFloor),
    make("ceiling", 1, arith.primCeiling),
    make("round", 1, arith.primRound),
    make("truncate", 1, arith.primTruncate),
    make("exact->inexact", 1, arith.primExactToInexact),
    make("inexact->exact", 1, arith.primInexactToExact),

    make("string-upcase", 1, pairs.primStringUpcase),
    make("string-downcase", 1, pairs.primStringDowncase),
    make("char->string", 1, pairs.primCharToString),

    make("write", 1, io_mod.primWrite),
    make("display-to-string", 1, io_mod.primDisplayToString),
    make("write-to-string", 1, io_mod.primWriteToString),
    make("format", -1, io_mod.primFormat),
    make("exit", -1, io_mod.primExit),
    make("argv", 0, io_mod.primArgv),
    make("read-line", -1, io_mod.primReadLine), // zepo-8e6, zepo-s4p: now variadic (0 or 1 arg)
    // zepo-s4p
    make("open-input-file", 1, io_mod.primOpenInputFile),
    make("close-input-port", 1, io_mod.primCloseInputPort),
    make("current-input-port", 0, io_mod.primCurrentInputPort),
    make("read-char", 1, io_mod.primReadChar),
    make("peek-char", 1, io_mod.primPeekChar),
    make("eof-object?", 1, io_mod.primEofObjectQ),
    make("eof-object", 0, io_mod.primEofObject),
    make("input-port?", 1, io_mod.primInputPortQ),

    make("file-read-string", 1, sys_mod.primFileReadString),
    make("file-write-string", 2, sys_mod.primFileWriteString),
    make("file-append-string", 2, sys_mod.primFileAppendString),
    make("file-exists?", 1, sys_mod.primFileExistsQ),
    make("file-delete", 1, sys_mod.primFileDelete),
    make("directory-list", 1, sys_mod.primDirectoryList),
    make("make-directory", 1, sys_mod.primMakeDirectory),
    make("current-directory", 0, sys_mod.primCurrentDirectory),
    make("getenv", 1, sys_mod.primGetenv),
    make("shell", 1, sys_mod.primShell),
    make("shell/status", 1, sys_mod.primShellStatus),
    // zepo-b3c
    make("file-directory?", 1, sys_mod.primFileDirectoryQ),
    make("file-size", 1, sys_mod.primFileSize),
    make("file-mtime", 1, sys_mod.primFileMtime),
    make("file-type", 1, sys_mod.primFileType),

    make("tui-run", 3, tui_mod.primTuiRun),
    make("tui-screen-size", 0, tui_mod.primTuiScreenSize),

    make("ffi-int", 1, ffi_accessors.primFfiInt),
    make("ffi-float", 1, ffi_accessors.primFfiFloat),
    make("ffi-bool", 1, ffi_accessors.primFfiBool),
    make("ffi-string", 1, ffi_accessors.primFfiString),
    make("ffi-to-lisp", 1, ffi_accessors.primFfiToLisp),

    make("json-parse", 1, ffi_json.primJsonParse),
    make("json-stringify", 1, ffi_json.primJsonStringify),
    make("json-null?", 1, ffi_json.primJsonNullQ),

    make("make-hash-table", 0, hashtable_prims.primMakeHashTable),
    make("hash-table?", 1, hashtable_prims.primHashTableQ),
    make("hash-set!", 3, hashtable_prims.primHashSet),
    make("hash-get", -1, hashtable_prims.primHashGet),
    make("hash-contains?", 2, hashtable_prims.primHashContainsQ),
    make("hash-delete!", 2, hashtable_prims.primHashDelete),
    make("hash-size", 1, hashtable_prims.primHashSize),
    make("hash-keys", 1, hashtable_prims.primHashKeys),
    make("hash-values", 1, hashtable_prims.primHashValues),
    make("hash-for-each", 2, hashtable_prims.primHashForEach),
    make("hash->alist", 1, hashtable_prims.primHashToAlist),
    make("alist->hash", 1, hashtable_prims.primAlistToHash),

    make("current-time-ms", 0, time_prims.primCurrentTimeMs),
    make("epoch->date", 1, time_prims.primEpochToDate),
    make("date->epoch", 6, time_prims.primDateToEpoch),
    make("time-format", 2, time_prims.primTimeFormat),

    make("tcp-connect", 2, net_prims.primTcpConnect),
    make("tcp-send", 2, net_prims.primTcpSend),
    make("tcp-recv", 2, net_prims.primTcpRecv),
    make("tcp-close", 1, net_prims.primTcpClose),
    make("tcp-socket?", 1, net_prims.primTcpSocketQ),
    make("tcp-server?", 1, net_prims.primTcpServerQ),
    make("tcp-listen", 1, net_prims.primTcpListen),
    make("tcp-accept", 1, net_prims.primTcpAccept),

    make("http-request", 4, http_prims.primHttpRequest),

    make("regex-compile", -1, regex_prims.primRegexCompile),
    make("regex-exec", 2, regex_prims.primRegexExec),
    make("regex?", 1, regex_prims.primRegexQ),

    make("sqrt", 1, math_prims.primSqrt),
    make("cbrt", 1, math_prims.primCbrt),
    make("exp", 1, math_prims.primExp),
    make("ln", 1, math_prims.primLn),
    make("log10", 1, math_prims.primLog10),
    make("log2", 1, math_prims.primLog2),
    make("sin", 1, math_prims.primSin),
    make("cos", 1, math_prims.primCos),
    make("tan", 1, math_prims.primTan),
    make("asin", 1, math_prims.primAsin),
    make("acos", 1, math_prims.primAcos),
    make("atan", 1, math_prims.primAtan),
    make("atan2", 2, math_prims.primAtan2),
    make("sinh", 1, math_prims.primSinh),
    make("cosh", 1, math_prims.primCosh),
    make("tanh", 1, math_prims.primTanh),
    make("abs", 1, math_prims.primAbs),
    make("pow", 2, math_prims.primPow),
    make("copysign", 2, math_prims.primCopysign),
    make("hypot", 2, math_prims.primHypot),
    make("fmod", 2, math_prims.primFmod),
    make("prim-inf", 0, math_prims.primInf),
    make("prim-neg-inf", 0, math_prims.primNegInf),
    make("prim-nan", 0, math_prims.primNan),
    make("nan?", 1, math_prims.primNanQ),
    make("finite?", 1, math_prims.primFiniteQ),
    make("infinite?", 1, math_prims.primInfiniteQ),

    // zepo-qny
    make("bitwise-and", -1, bitwise_prims.primBitwiseAnd),
    make("bitwise-or", -1, bitwise_prims.primBitwiseOr),
    make("bitwise-xor", -1, bitwise_prims.primBitwiseXor),
    make("bitwise-not", 1, bitwise_prims.primBitwiseNot),
    make("arithmetic-shift", 2, bitwise_prims.primArithmeticShift),
    make("bit-count", 1, bitwise_prims.primBitCount),

    // zepo-6qx
    make("signal-set!", 2, signal_prims.primSignalSet),
    make("signal-number", 1, signal_prims.primSignalNumber),
    make("getpid", 0, signal_prims.primGetpid),
};

pub fn registerAll(gc: *GC, globals: *GlobalEnv, symbols: *SymbolTable) !void {
    for (TABLE) |e| {
        const sym = try symbols.intern(e.name);
        const raw_ptr: u64 = @intCast(@intFromPtr(e.fn_ptr));
        const prim = try objects.makePrim(gc, raw_ptr, e.arity);
        try globals.define(sym, prim);
    }
    if (builtin.mode == .Debug) {
        const debug_table = &[_]Entry{
            make("zepo/debug-value", 1, debug_prims.primDebugValue),
            make("zepo/gc-stats",    0, debug_prims.primGcStats),
        };
        for (debug_table) |e| {
            const sym = try symbols.intern(e.name);
            const raw_ptr: u64 = @intCast(@intFromPtr(e.fn_ptr));
            const prim = try objects.makePrim(gc, raw_ptr, e.arity);
            try globals.define(sym, prim);
        }
    }
}
