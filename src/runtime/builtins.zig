//! The built-in objects and functions ZQJS implements (DESIGN_DECISIONS D39), and global
//! name lookup.
//!
//! Three kinds of names, for globals and for properties of built-in objects:
//!   implemented   here, with their behaviour (the only ones that produce values)
//!   known         node has them (builtin_names.zig, generated from node) but ZQJS
//!                 doesn't implement them: Unsupported(builtin), naming the member
//!   nonexistent   neither: a global is a ReferenceError, a property `undefined`
//!
//! Implemented in M7:
//!   globals             undefined NaN Infinity print Object Array
//!   Object              keys create getPrototypeOf
//!   Array               isArray
//!   Object.prototype    toString valueOf
//!   Array.prototype     push pop join toString
//!   String.prototype    charCodeAt
//! Calling `Object(…)` or `Array(…)` themselves is Unsupported(builtin).
//!
//! The realm (the built-in objects) is created on first use, so creating a Runtime
//! can't fail. GC roots (D38): every object in Realm.

const std = @import("std");
const Value = @import("value.zig").Value;
const Native = @import("value.zig").Native;
const heap_mod = @import("heap.zig");
const Object = heap_mod.Object;
const rt_mod = @import("runtime.zig");
const clone = @import("clone.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const object = @import("object.zig");
const names = @import("builtin_names.zig");
const json = @import("json.zig");

const common = @import("builtins/common.zig");
const function_error = @import("builtins/function_error.zig");
const object_builtins = @import("builtins/object.zig");
const array = @import("builtins/array.zig");
const string = @import("builtins/string.zig");
const number_math = @import("builtins/number_math.zig");
const collections = @import("builtins/collections.zig");
const promise = @import("builtins/promise.zig");
const iterator = @import("builtins/iterator.zig");
const regexp = @import("builtins/regexp.zig");
const typed_array = @import("builtins/typed_array.zig");
const proxy_reflect = @import("builtins/proxy_reflect.zig");
const encoding = @import("builtins/encoding.zig");

// Re-export public built-in APIs so callers outside `src/runtime/builtins*` keep the exact facade.
pub const viewsRealm = typed_array.viewsRealm;
pub const hasAutoPrototype = function_error.hasAutoPrototype;
pub const isGeneratorFunction = function_error.isGeneratorFunction;
pub const FunctionKind = function_error.FunctionKind;
pub const functionKind = function_error.functionKind;
pub const closureDefaultProto = function_error.closureDefaultProto;
pub const isConstructor = function_error.isConstructor;
pub const checkFunctionRealm = proxy_reflect.checkFunctionRealm;
pub const closureName = function_error.closureName;
pub const closureLength = function_error.closureLength;
pub const isClassConstructor = function_error.isClassConstructor;
pub const setupClass = function_error.setupClass;
pub const runInstanceInits = function_error.runInstanceInits;
pub const defineClassMethod = function_error.defineClassMethod;
pub const defineClassAccessor = function_error.defineClassAccessor;
pub const setFunctionNameIfUnset = function_error.setFunctionNameIfUnset;
pub const materializeClosurePrototype = function_error.materializeClosurePrototype;
pub const makeEngineError = function_error.makeEngineError;
pub const newArgumentsObject = object_builtins.newArgumentsObject;
pub const newMappedArgumentsObject = object_builtins.newMappedArgumentsObject;
pub const defineOwnPropertyParsed = object_builtins.defineOwnPropertyParsed;
pub const ordinarySetWithReceiver = object_builtins.ordinarySetWithReceiver;
pub const forInInit = object_builtins.forInInit;
pub const forInNext = object_builtins.forInNext;
pub const isArray = array.isArray;
pub const toStringObj = common.toStringObj;
pub const getTemplateObjectFromConsts = string.getTemplateObjectFromConsts;
pub const getTemplateObjectFromUnits = string.getTemplateObjectFromUnits;
pub const performPromiseThen = promise.performPromiseThen;
pub const performPromiseThenCap = promise.performPromiseThenCap;
pub const resolveToPromise = promise.resolveToPromise;
pub const callPromiseCapability = promise.callPromiseCapability;
pub const resolvePromiseValue = promise.resolvePromiseValue;
pub const adoptPromiseNow = promise.adoptPromiseNow;
pub const settlePromiseFromJob = promise.settlePromiseFromJob;
pub const getIterator = iterator.getIterator;
pub const iteratorNextVal = iterator.iteratorNextVal;
pub const iteratorClose = iterator.iteratorClose;
pub const iterResult = iterator.iterResult;
pub const YieldStarStep = iterator.YieldStarStep;
pub const yieldStarStep = iterator.yieldStarStep;
pub const getAsyncIterator = iterator.getAsyncIterator;
pub const asyncIterNext = iterator.asyncIterNext;
pub const asyncIterValue = iterator.asyncIterValue;
pub const asyncIterCloseStart = iterator.asyncIterCloseStart;
pub const asyncIterCloseCheck = iterator.asyncIterCloseCheck;
pub const AsyncYieldStar = iterator.AsyncYieldStar;
pub const asyncYieldStarCall = iterator.asyncYieldStarCall;
pub const asyncYieldStarResult = iterator.asyncYieldStarResult;
pub const createRegExp = regexp.createRegExp;
pub const newRegExpFromStrings = regexp.newRegExpFromStrings;
pub const newRegExpFromLiteral = regexp.newRegExpFromLiteral;
pub const proxyGet = proxy_reflect.proxyGet;
pub const proxySet = proxy_reflect.proxySet;
pub const proxyHas = proxy_reflect.proxyHas;
pub const proxyDeleteProperty = proxy_reflect.proxyDeleteProperty;
pub const proxyGetPrototypeOf = proxy_reflect.proxyGetPrototypeOf;
pub const proxyGetOwnPropertyDescriptor = proxy_reflect.proxyGetOwnPropertyDescriptor;
pub const ProxyKeyFilter = proxy_reflect.ProxyKeyFilter;
pub const proxyOwnKeysFiltered = proxy_reflect.proxyOwnKeysFiltered;
pub const proxyOwnSymbolKeys = proxy_reflect.proxyOwnSymbolKeys;
pub const callProxy = proxy_reflect.callProxy;
pub const callProxyConstruct = proxy_reflect.callProxyConstruct;

pub const Realm = struct {
    object_prototype: *Object,
    array_prototype: *Object,
    string_prototype: *Object,
    number_prototype: *Object,
    boolean_prototype: *Object,
    function_prototype: *Object,
    function_namespace: *Object,
    map_prototype: *Object,
    set_prototype: *Object,
    weak_map_prototype: *Object,
    weak_set_prototype: *Object,
    promise_prototype: *Object,
    iterator_namespace: *Object,
    iterator_prototype: *Object,
    array_iterator_prototype: *Object,
    string_iterator_prototype: *Object,
    regexp_string_iterator_prototype: *Object,
    map_iterator_prototype: *Object,
    set_iterator_prototype: *Object,
    iterator_helper_prototype: *Object,
    iterator_wrap_prototype: *Object,
    /// %GeneratorPrototype% (D67).
    generator_prototype: *Object,
    /// D68: %AsyncIteratorPrototype%, %AsyncGeneratorPrototype%, the internal
    /// %AsyncFromSyncIteratorPrototype%, and the `[[Prototype]]`s of generator, async
    /// generator and async functions.
    async_iterator_prototype: *Object,
    async_generator_prototype: *Object,
    async_from_sync_iterator_prototype: *Object,
    generator_function_prototype: *Object,
    async_generator_function_prototype: *Object,
    async_function_prototype: *Object,
    error_prototype: *Object,
    type_error_prototype: *Object,
    range_error_prototype: *Object,
    syntax_error_prototype: *Object,
    reference_error_prototype: *Object,
    eval_error_prototype: *Object,
    uri_error_prototype: *Object,
    aggregate_error_prototype: *Object,
    regexp_prototype: *Object,
    date_prototype: *Object,
    /// Static members of the `Object`, `Array`, `String`, `Number`, `Map`, `Set`, `Promise`, `Error`, `RegExp`, and `Date` globals.
    object_namespace: *Object,
    array_namespace: *Object,
    string_namespace: *Object,
    number_namespace: *Object,
    boolean_namespace: *Object,
    map_namespace: *Object,
    set_namespace: *Object,
    weak_map_namespace: *Object,
    weak_set_namespace: *Object,
    proxy_namespace: *Object,
    reflect: *Object,
    promise_namespace: *Object,
    error_namespace: *Object,
    type_error_namespace: *Object,
    range_error_namespace: *Object,
    syntax_error_namespace: *Object,
    reference_error_namespace: *Object,
    eval_error_namespace: *Object,
    uri_error_namespace: *Object,
    aggregate_error_namespace: *Object,
    regexp_namespace: *Object,
    date_namespace: *Object,
    symbol_prototype: *Object,
    symbol_namespace: *Object,
    bigint_prototype: *Object,
    bigint_namespace: *Object,
    sym_iterator: *heap_mod.Symbol,
    /// `Symbol.asyncIterator` (D68).
    sym_async_iterator: *heap_mod.Symbol,
    sym_to_primitive: *heap_mod.Symbol,
    sym_to_string_tag: *heap_mod.Symbol,
    sym_has_instance: *heap_mod.Symbol,
    sym_species: *heap_mod.Symbol,
    sym_match: *heap_mod.Symbol,
    sym_replace: *heap_mod.Symbol,
    sym_search: *heap_mod.Symbol,
    sym_split: *heap_mod.Symbol,
    sym_match_all: *heap_mod.Symbol,
    sym_is_concat_spreadable: *heap_mod.Symbol,
    math: *Object,
    json: *Object,
    console: *Object,
    text_encoder_prototype: *Object,
    text_encoder_namespace: *Object,
    text_decoder_prototype: *Object,
    text_decoder_namespace: *Object,
    text_encoders: *Object,
    text_decoders: *Object,
    global_object: *Object,
    views: ?ViewsRealm = null,

    /// For GC roots (M8) and tests.
    pub fn objects(r: *const Realm) [74]*Object {
        return .{
            r.object_prototype,
            r.array_prototype,
            r.string_prototype,
            r.number_prototype,
            r.boolean_prototype,
            r.function_prototype,
            r.function_namespace,
            r.map_prototype,
            r.set_prototype,
            r.weak_map_prototype,
            r.weak_set_prototype,
            r.promise_prototype,
            r.iterator_namespace,
            r.iterator_prototype,
            r.array_iterator_prototype,
            r.string_iterator_prototype,
            r.regexp_string_iterator_prototype,
            r.map_iterator_prototype,
            r.set_iterator_prototype,
            r.iterator_helper_prototype,
            r.iterator_wrap_prototype,
            r.generator_prototype,
            r.async_iterator_prototype,
            r.async_generator_prototype,
            r.async_from_sync_iterator_prototype,
            r.generator_function_prototype,
            r.async_generator_function_prototype,
            r.async_function_prototype,
            r.error_prototype,
            r.type_error_prototype,
            r.range_error_prototype,
            r.syntax_error_prototype,
            r.reference_error_prototype,
            r.eval_error_prototype,
            r.uri_error_prototype,
            r.aggregate_error_prototype,
            r.regexp_prototype,
            r.date_prototype,
            r.symbol_prototype,
            r.bigint_prototype,
            r.object_namespace,
            r.array_namespace,
            r.string_namespace,
            r.number_namespace,
            r.boolean_namespace,
            r.map_namespace,
            r.set_namespace,
            r.weak_map_namespace,
            r.weak_set_namespace,
            r.proxy_namespace,
            r.reflect,
            r.promise_namespace,
            r.error_namespace,
            r.type_error_namespace,
            r.range_error_namespace,
            r.syntax_error_namespace,
            r.reference_error_namespace,
            r.eval_error_namespace,
            r.uri_error_namespace,
            r.aggregate_error_namespace,
            r.regexp_namespace,
            r.date_namespace,
            r.symbol_namespace,
            r.bigint_namespace,
            r.math,
            r.json,
            r.console,
            r.text_encoder_prototype,
            r.text_encoder_namespace,
            r.text_decoder_prototype,
            r.text_decoder_namespace,
            r.text_encoders,
            r.text_decoders,
            r.global_object,
        };
    }
};

pub const ViewsRealm = struct {
    array_buffer_prototype: *Object,
    array_buffer_namespace: *Object,
    data_view_prototype: *Object,
    data_view_namespace: *Object,
    typed_array_prototype: *Object,
    typed_array_namespace: *Object,
    typed_array_prototypes: [11]*Object,
    typed_array_namespaces: [11]*Object,

    pub fn objects(v: *const ViewsRealm) [28]*Object {
        return .{
            v.array_buffer_prototype,
            v.array_buffer_namespace,
            v.data_view_prototype,
            v.data_view_namespace,
            v.typed_array_prototype,
            v.typed_array_namespace,
            v.typed_array_prototypes[0],
            v.typed_array_prototypes[1],
            v.typed_array_prototypes[2],
            v.typed_array_prototypes[3],
            v.typed_array_prototypes[4],
            v.typed_array_prototypes[5],
            v.typed_array_prototypes[6],
            v.typed_array_prototypes[7],
            v.typed_array_prototypes[8],
            v.typed_array_prototypes[9],
            v.typed_array_prototypes[10],
            v.typed_array_namespaces[0],
            v.typed_array_namespaces[1],
            v.typed_array_namespaces[2],
            v.typed_array_namespaces[3],
            v.typed_array_namespaces[4],
            v.typed_array_namespaces[5],
            v.typed_array_namespaces[6],
            v.typed_array_namespaces[7],
            v.typed_array_namespaces[8],
            v.typed_array_namespaces[9],
            v.typed_array_namespaces[10],
        };
    }
};

pub fn realm(rt: *Runtime) Error!*const Realm {
    if (rt.realm) |*r| return r;
    const h = &rt.heap;
    const object_prototype = try common.builtin(h, null, .object_prototype);
    const error_prototype = try common.builtin(h, object_prototype, .error_prototype);
    const iterator_prototype = try common.builtin(h, object_prototype, .iterator_prototype);
    const async_iterator_prototype = try common.builtin(h, object_prototype, .async_iterator_prototype);
    const function_prototype = try common.builtin(h, object_prototype, .function_prototype);
    var r: Realm = .{
        .object_prototype = object_prototype,
        .array_prototype = try common.builtin(h, object_prototype, .array_prototype),
        .string_prototype = try common.builtin(h, object_prototype, .string_prototype),
        .number_prototype = try common.builtin(h, object_prototype, .number_prototype),
        .boolean_prototype = try common.builtin(h, object_prototype, .boolean_prototype),
        .function_prototype = function_prototype,
        .function_namespace = try common.builtin(h, null, .function_constructor),
        .map_prototype = try common.builtin(h, object_prototype, .map_prototype),
        .set_prototype = try common.builtin(h, object_prototype, .set_prototype),
        .weak_map_prototype = try common.builtin(h, object_prototype, .weak_map_prototype),
        .weak_set_prototype = try common.builtin(h, object_prototype, .weak_set_prototype),
        .promise_prototype = try common.builtin(h, object_prototype, .promise_prototype),
        .iterator_namespace = try h.newObject(function_prototype),
        .iterator_prototype = iterator_prototype,
        .array_iterator_prototype = try h.newObject(iterator_prototype),
        .string_iterator_prototype = try h.newObject(iterator_prototype),
        .regexp_string_iterator_prototype = try h.newObject(iterator_prototype),
        .map_iterator_prototype = try h.newObject(iterator_prototype),
        .set_iterator_prototype = try h.newObject(iterator_prototype),
        .iterator_helper_prototype = try h.newObject(iterator_prototype),
        .iterator_wrap_prototype = try h.newObject(iterator_prototype),
        .generator_prototype = try common.builtin(h, iterator_prototype, .generator_prototype),
        .async_iterator_prototype = async_iterator_prototype,
        .async_generator_prototype = try common.builtin(h, async_iterator_prototype, .async_generator_prototype),
        .async_from_sync_iterator_prototype = try h.newObject(async_iterator_prototype),
        .generator_function_prototype = try common.builtin(h, function_prototype, .generator_function_prototype),
        .async_generator_function_prototype = try common.builtin(h, function_prototype, .async_generator_function_prototype),
        .async_function_prototype = try common.builtin(h, function_prototype, .async_function_prototype),
        .error_prototype = error_prototype,
        .type_error_prototype = try common.builtin(h, error_prototype, .type_error_prototype),
        .range_error_prototype = try common.builtin(h, error_prototype, .range_error_prototype),
        .syntax_error_prototype = try common.builtin(h, error_prototype, .syntax_error_prototype),
        .reference_error_prototype = try common.builtin(h, error_prototype, .reference_error_prototype),
        .eval_error_prototype = try common.builtin(h, error_prototype, .eval_error_prototype),
        .uri_error_prototype = try common.builtin(h, error_prototype, .uri_error_prototype),
        .aggregate_error_prototype = try common.builtin(h, error_prototype, .aggregate_error_prototype),
        .regexp_prototype = try common.builtin(h, object_prototype, .regexp_prototype),
        .date_prototype = try common.builtin(h, object_prototype, .date_prototype),
        .object_namespace = try common.builtin(h, null, .object_constructor),
        .array_namespace = try common.builtin(h, null, .array_constructor),
        .string_namespace = try common.builtin(h, null, .string_constructor),
        .number_namespace = try common.builtin(h, null, .number_constructor),
        .boolean_namespace = try h.newObject(null),
        .map_namespace = try common.builtin(h, null, .map_constructor),
        .set_namespace = try common.builtin(h, null, .set_constructor),
        .weak_map_namespace = try common.builtin(h, null, .weak_map_constructor),
        .weak_set_namespace = try common.builtin(h, null, .weak_set_constructor),
        .proxy_namespace = try common.builtin(h, null, .proxy_constructor),
        .reflect = try common.builtin(h, object_prototype, .reflect),
        .promise_namespace = try common.builtin(h, null, .promise_constructor),
        .error_namespace = try common.builtin(h, null, .error_constructor),
        .type_error_namespace = try common.builtin(h, null, .type_error_constructor),
        .range_error_namespace = try common.builtin(h, null, .range_error_constructor),
        .syntax_error_namespace = try common.builtin(h, null, .syntax_error_constructor),
        .reference_error_namespace = try common.builtin(h, null, .reference_error_constructor),
        .eval_error_namespace = try common.builtin(h, null, .eval_error_constructor),
        .uri_error_namespace = try common.builtin(h, null, .uri_error_constructor),
        .aggregate_error_namespace = try common.builtin(h, null, .aggregate_error_constructor),
        .regexp_namespace = try common.builtin(h, null, .regexp_constructor),
        .date_namespace = try common.builtin(h, null, .date_constructor),
        .symbol_prototype = try common.builtin(h, object_prototype, .symbol_prototype),
        .symbol_namespace = try common.builtin(h, null, .symbol_constructor),
        .bigint_prototype = try common.builtin(h, object_prototype, .bigint_prototype),
        .bigint_namespace = try common.builtin(h, null, .bigint_constructor),
        .sym_iterator = try h.newSymbol(try h.ascii("Symbol.iterator"), false),
        .sym_async_iterator = try h.newSymbol(try h.ascii("Symbol.asyncIterator"), false),
        .sym_to_primitive = try h.newSymbol(try h.ascii("Symbol.toPrimitive"), false),
        .sym_to_string_tag = try h.newSymbol(try h.ascii("Symbol.toStringTag"), false),
        .sym_has_instance = try h.newSymbol(try h.ascii("Symbol.hasInstance"), false),
        .sym_species = try h.newSymbol(try h.ascii("Symbol.species"), false),
        .sym_match = try h.newSymbol(try h.ascii("Symbol.match"), false),
        .sym_replace = try h.newSymbol(try h.ascii("Symbol.replace"), false),
        .sym_search = try h.newSymbol(try h.ascii("Symbol.search"), false),
        .sym_split = try h.newSymbol(try h.ascii("Symbol.split"), false),
        .sym_match_all = try h.newSymbol(try h.ascii("Symbol.matchAll"), false),
        .sym_is_concat_spreadable = try h.newSymbol(try h.ascii("Symbol.isConcatSpreadable"), false),
        .math = try common.builtin(h, object_prototype, .math),
        .json = try common.builtin(h, object_prototype, .json),
        .console = try h.newObject(object_prototype),
        .text_encoder_prototype = try h.newObject(object_prototype),
        .text_encoder_namespace = try h.newObject(null),
        .text_decoder_prototype = try h.newObject(object_prototype),
        .text_decoder_namespace = try h.newObject(null),
        .text_encoders = try h.newWeakSet(null),
        .text_decoders = try h.newWeakMap(null),
        .global_object = try common.builtin(h, object_prototype, .global),
    };
    try object_builtins.register(rt, &r);
    try array.register(rt, &r);
    try string.register(rt, &r);
    try number_math.register(rt, &r);
    try proxy_reflect.register(rt, &r);
    try collections.register(rt, &r);
    try promise.register(rt, &r);
    try iterator.register(rt, &r);
    try common.method(rt, r.json, "parse", &json.parse_native);
    try common.method(rt, r.json, "stringify", &json.stringify_native);
    try common.defineToStringTag(rt, r.json, r.sym_to_string_tag, "JSON");
    // WHATWG Console namespace: methods are enumerable/writable/configurable own properties.
    for ([_]struct { []const u8, *const Native }{
        .{ "log", &console_log },
        .{ "info", &console_info },
        .{ "debug", &console_debug },
        .{ "warn", &console_warn },
        .{ "error", &console_error },
        .{ "assert", &console_assert },
    }) |entry| {
        const k = try h.internAscii(entry[0]);
        try h.defineProperty(r.console, k, .{ .value = Value.fromNative(entry[1]) });
    }
    try common.defineToStringTag(rt, r.console, r.sym_to_string_tag, "console");
    try function_error.register(rt, &r);
    try regexp.register(rt, &r);
    try encoding.register(rt, &r);
    for (builtin_globals.keys(), 0..) |name, i| {
        const target = builtin_globals.values()[i];
        const is_const = target == .undefined or target == .nan or target == .inf;
        const is_enumerable = std.mem.eql(u8, name, "atob") or std.mem.eql(u8, name, "btoa");
        const k = try h.internAscii(name);
        try h.defineProperty(r.global_object, k, .{
            .value = resolveGlobalTargetByIndex(&r, @intCast(i)),
            .enumerable = is_enumerable,
            .writable = !is_const,
            .configurable = !is_const,
        });
    }
    _ = &r;
    rt.realm = r;
    return &rt.realm.?;
}

pub const function_has_instance: Native = .{ .name = "[Symbol.hasInstance]", .length = 1, .call = function_error.functionHasInstance };

pub const array_buffer_global: Native = .{
    .name = "ArrayBuffer",
    .length = 1,
    .call = typed_array.arrayBufferWithoutNew,
    .construct = typed_array.arrayBufferConstruct,
    .namespace = .array_buffer,
};

pub const data_view_global: Native = .{
    .name = "DataView",
    .length = 1,
    .call = typed_array.dataViewWithoutNew,
    .construct = typed_array.dataViewConstruct,
    .namespace = .data_view,
};

pub const typed_array_global: Native = .{
    .name = "TypedArray",
    .length = 0,
    .call = typed_array.typedArrayAbstractCall,
    .construct = typed_array.typedArrayAbstractConstruct,
    .namespace = .typed_array,
};

pub const typed_array_ctors: [11]Native = .{
    .{ .name = "Int8Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructInt8, .namespace = .int8_array },
    .{ .name = "Uint8Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructUint8, .namespace = .uint8_array },
    .{ .name = "Uint8ClampedArray", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructUint8Clamped, .namespace = .uint8_clamped_array },
    .{ .name = "Int16Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructInt16, .namespace = .int16_array },
    .{ .name = "Uint16Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructUint16, .namespace = .uint16_array },
    .{ .name = "Int32Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructInt32, .namespace = .int32_array },
    .{ .name = "Uint32Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructUint32, .namespace = .uint32_array },
    .{ .name = "Float32Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructFloat32, .namespace = .float32_array },
    .{ .name = "Float64Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructFloat64, .namespace = .float64_array },
    .{ .name = "BigInt64Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructBigInt64, .namespace = .bigint64_array },
    .{ .name = "BigUint64Array", .length = 3, .call = typed_array.typedArrayWithoutNew, .construct = typed_array.typedArrayConstructBigUint64, .namespace = .biguint64_array },
};

const proxy_global: Native = .{
    .name = "Proxy",
    .length = 2,
    .call = proxy_reflect.proxyCallThrow,
    .construct = proxy_reflect.proxyConstruct,
    .namespace = .proxy,
};

pub fn namespaceObject(rt: *Runtime, n: *const Native) Error!?*Object {
    const ns = n.namespace orelse return null;
    const r = try realm(rt);
    return switch (ns) {
        .object => r.object_namespace,
        .array => r.array_namespace,
        .string => r.string_namespace,
        .number => r.number_namespace,
        .boolean => r.boolean_namespace,
        .function => r.function_namespace,
        .map => r.map_namespace,
        .set => r.set_namespace,
        .weak_map => r.weak_map_namespace,
        .weak_set => r.weak_set_namespace,
        .iterator => r.iterator_namespace,
        .proxy => r.proxy_namespace,
        .promise => r.promise_namespace,
        .@"error" => r.error_namespace,
        .type_error => r.type_error_namespace,
        .range_error => r.range_error_namespace,
        .syntax_error => r.syntax_error_namespace,
        .reference_error => r.reference_error_namespace,
        .eval_error => r.eval_error_namespace,
        .uri_error => r.uri_error_namespace,
        .aggregate_error => r.aggregate_error_namespace,
        .regexp => r.regexp_namespace,
        .date => r.date_namespace,
        .symbol => r.symbol_namespace,
        .bigint => r.bigint_namespace,
        .array_buffer => (try typed_array.viewsRealm(rt)).array_buffer_namespace,
        .data_view => (try typed_array.viewsRealm(rt)).data_view_namespace,
        .typed_array => (try typed_array.viewsRealm(rt)).typed_array_namespace,
        .int8_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[0],
        .uint8_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[1],
        .uint8_clamped_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[2],
        .int16_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[3],
        .uint16_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[4],
        .int32_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[5],
        .uint32_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[6],
        .float32_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[7],
        .float64_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[8],
        .bigint64_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[9],
        .biguint64_array => (try typed_array.viewsRealm(rt)).typed_array_namespaces[10],
        .text_encoder => r.text_encoder_namespace,
        .text_decoder => r.text_decoder_namespace,
    };
}

pub fn nativeProto(rt: *Runtime, n: *const Native) Error!Value {
    const ns = n.namespace orelse return Value.fromObject((try realm(rt)).function_prototype);
    return switch (ns) {
        .int8_array,
        .uint8_array,
        .uint8_clamped_array,
        .int16_array,
        .uint16_array,
        .int32_array,
        .uint32_array,
        .float32_array,
        .float64_array,
        .bigint64_array,
        .biguint64_array,
        => Value.fromNative(&typed_array_global),
        else => Value.fromObject((try realm(rt)).function_prototype),
    };
}

pub fn constructorPrototype(rt: *Runtime, n: *const Native) Error!?*Object {
    const ns = n.namespace orelse return null;
    const r = try realm(rt);
    return switch (ns) {
        .object => r.object_prototype,
        .array => r.array_prototype,
        .string => r.string_prototype,
        .number => r.number_prototype,
        .boolean => r.boolean_prototype,
        .function => r.function_prototype,
        .map => r.map_prototype,
        .set => r.set_prototype,
        .weak_map => r.weak_map_prototype,
        .weak_set => r.weak_set_prototype,
        .iterator => r.iterator_prototype,
        .proxy => null,
        .promise => r.promise_prototype,
        .@"error" => r.error_prototype,
        .type_error => r.type_error_prototype,
        .range_error => r.range_error_prototype,
        .syntax_error => r.syntax_error_prototype,
        .reference_error => r.reference_error_prototype,
        .eval_error => r.eval_error_prototype,
        .uri_error => r.uri_error_prototype,
        .aggregate_error => r.aggregate_error_prototype,
        .regexp => r.regexp_prototype,
        .date => r.date_prototype,
        .symbol => r.symbol_prototype,
        .bigint => r.bigint_prototype,
        .array_buffer => (try typed_array.viewsRealm(rt)).array_buffer_prototype,
        .data_view => (try typed_array.viewsRealm(rt)).data_view_prototype,
        .typed_array => (try typed_array.viewsRealm(rt)).typed_array_prototype,
        .int8_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[0],
        .uint8_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[1],
        .uint8_clamped_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[2],
        .int16_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[3],
        .uint16_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[4],
        .int32_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[5],
        .uint32_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[6],
        .float32_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[7],
        .float64_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[8],
        .bigint64_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[9],
        .biguint64_array => (try typed_array.viewsRealm(rt)).typed_array_prototypes[10],
        .text_encoder => r.text_encoder_prototype,
        .text_decoder => r.text_decoder_prototype,
    };
}

// ---------------------------------------------------------------- globals

pub const print: Native = .{ .name = "print", .call = common.printImpl };
pub const console_log: Native = .{ .name = "log", .call = common.consoleLogImpl };
pub const console_info: Native = .{ .name = "info", .call = common.consoleLogImpl };
pub const console_debug: Native = .{ .name = "debug", .call = common.consoleLogImpl };
pub const console_warn: Native = .{ .name = "warn", .call = common.consoleLogImpl };
pub const console_error: Native = .{ .name = "error", .call = common.consoleLogImpl };
pub const console_assert: Native = .{ .name = "assert", .call = common.consoleAssertImpl };
pub const object_global: Native = .{ .name = "Object", .length = 1, .call = object_builtins.objectCall, .construct = object_builtins.objectConstruct, .namespace = .object };
pub const array_global: Native = .{ .name = "Array", .length = 1, .call = array.arrayCall, .construct = array.arrayConstruct, .namespace = .array };
pub const string_global: Native = .{ .name = "String", .length = 1, .call = string.stringCall, .construct = string.stringConstruct, .namespace = .string };
pub const number_global: Native = .{ .name = "Number", .length = 1, .call = number_math.numberCall, .construct = number_math.numberConstruct, .namespace = .number };
pub const boolean_global: Native = .{ .name = "Boolean", .length = 1, .call = number_math.booleanCall, .construct = number_math.booleanConstruct, .namespace = .boolean };
pub const function_global: Native = .{ .name = "Function", .length = 1, .call = common.notCallable, .namespace = .function };
pub const parse_int_global: Native = .{ .name = "parseInt", .length = 2, .call = number_math.parseIntImpl };
pub const parse_float_global: Native = .{ .name = "parseFloat", .length = 1, .call = number_math.parseFloatImpl };
pub const is_nan_global: Native = .{ .name = "isNaN", .length = 1, .call = number_math.globalIsNaN };
pub const is_finite_global: Native = .{ .name = "isFinite", .length = 1, .call = number_math.globalIsFinite };
pub const encode_uri_global: Native = .{ .name = "encodeURI", .length = 1, .call = number_math.globalEncodeURI };
pub const decode_uri_global: Native = .{ .name = "decodeURI", .length = 1, .call = number_math.globalDecodeURI };
pub const encode_uri_component_global: Native = .{ .name = "encodeURIComponent", .length = 1, .call = number_math.globalEncodeURIComponent };
pub const decode_uri_component_global: Native = .{ .name = "decodeURIComponent", .length = 1, .call = number_math.globalDecodeURIComponent };
pub const map_global: Native = .{ .name = "Map", .call = collections.mapWithoutNew, .construct = collections.mapConstruct, .namespace = .map };
pub const set_global: Native = .{ .name = "Set", .call = collections.setWithoutNew, .construct = collections.setConstruct, .namespace = .set };
pub const weak_map_global: Native = .{ .name = "WeakMap", .call = collections.weakMapWithoutNew, .construct = collections.weakMapConstruct, .namespace = .weak_map };
pub const weak_set_global: Native = .{ .name = "WeakSet", .call = collections.weakSetWithoutNew, .construct = collections.weakSetConstruct, .namespace = .weak_set };
pub const iterator_global: Native = .{ .name = "Iterator", .call = iterator.iteratorWithoutNew, .construct = iterator.iteratorConstruct, .namespace = .iterator };
pub const promise_global: Native = .{ .name = "Promise", .length = 1, .call = promise.promiseWithoutNew, .construct = promise.promiseConstruct, .namespace = .promise };
pub const error_global: Native = .{ .name = "Error", .length = 1, .call = function_error.errorCall, .construct = function_error.errorConstruct, .namespace = .@"error" };
pub const type_error_global: Native = .{ .name = "TypeError", .length = 1, .call = function_error.typeErrorCall, .construct = function_error.typeErrorConstruct, .namespace = .type_error };
pub const range_error_global: Native = .{ .name = "RangeError", .length = 1, .call = function_error.rangeErrorCall, .construct = function_error.rangeErrorConstruct, .namespace = .range_error };
pub const syntax_error_global: Native = .{ .name = "SyntaxError", .length = 1, .call = function_error.syntaxErrorCall, .construct = function_error.syntaxErrorConstruct, .namespace = .syntax_error };
pub const reference_error_global: Native = .{ .name = "ReferenceError", .length = 1, .call = function_error.referenceErrorCall, .construct = function_error.referenceErrorConstruct, .namespace = .reference_error };
pub const eval_error_global: Native = .{ .name = "EvalError", .length = 1, .call = function_error.evalErrorCall, .construct = function_error.evalErrorConstruct, .namespace = .eval_error };
pub const uri_error_global: Native = .{ .name = "URIError", .length = 1, .call = function_error.uriErrorCall, .construct = function_error.uriErrorConstruct, .namespace = .uri_error };
pub const aggregate_error_global: Native = .{ .name = "AggregateError", .length = 2, .call = function_error.aggregateErrorCall, .construct = function_error.aggregateErrorConstruct, .namespace = .aggregate_error };
pub const regexp_global: Native = .{ .name = "RegExp", .length = 2, .call = regexp.regexpCall, .construct = regexp.regexpConstruct, .namespace = .regexp };
pub const date_global: Native = .{ .name = "Date", .length = 7, .call = number_math.dateCall, .construct = number_math.dateConstruct, .namespace = .date };
pub const symbol_global: Native = .{ .name = "Symbol", .call = number_math.symbolCall, .namespace = .symbol };
pub const bigint_global: Native = .{ .name = "BigInt", .length = 1, .call = number_math.bigintCall, .namespace = .bigint };
pub const structured_clone_global: Native = .{ .name = "structuredClone", .length = 1, .call = structuredCloneCall };
pub const atob_global: Native = .{ .name = "atob", .length = 1, .call = encoding.atobImpl };
pub const btoa_global: Native = .{ .name = "btoa", .length = 1, .call = encoding.btoaImpl };
pub const text_encoder_global: Native = .{ .name = "TextEncoder", .length = 0, .call = encoding.textEncoderWithoutNew, .construct = encoding.textEncoderConstruct, .namespace = .text_encoder };
pub const text_decoder_global: Native = .{ .name = "TextDecoder", .length = 0, .call = encoding.textDecoderWithoutNew, .construct = encoding.textDecoderConstruct, .namespace = .text_decoder };

fn structuredCloneCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return clone.structuredCloneImpl(rt, args);
}

/// A global read: implemented, host-registered (M9.1, D53), known to node (Unsupported),
/// or a ReferenceError.
pub fn global(rt: *Runtime, name: []const u8) Error!Value {
    return (try lookupGlobal(rt, name)) orelse
        rt.throw(.ReferenceError, &.{ .{ .ascii = name }, .{ .ascii = " is not defined" } });
}

/// Non-throwing global lookup for `typeof undeclared`: returns `undefined` if unknown.
pub fn tryGlobal(rt: *Runtime, name: []const u8) Error!Value {
    return (try lookupGlobal(rt, name)) orelse .undefined;
}

const GlobalTarget = union(enum) {
    undefined,
    nan,
    inf,
    math,
    json,
    console,
    reflect,
    global_this,
    native: *const Native,
};

const builtin_globals = std.StaticStringMap(GlobalTarget).initComptime([_]struct { []const u8, GlobalTarget }{
    .{ "undefined", .undefined },
    .{ "NaN", .nan },
    .{ "Infinity", .inf },
    .{ "globalThis", .global_this },
    .{ "print", .{ .native = &print } },
    .{ "Object", .{ .native = &object_global } },
    .{ "Array", .{ .native = &array_global } },
    .{ "String", .{ .native = &string_global } },
    .{ "Number", .{ .native = &number_global } },
    .{ "Boolean", .{ .native = &boolean_global } },
    .{ "Function", .{ .native = &function_global } },
    .{ "parseInt", .{ .native = &parse_int_global } },
    .{ "parseFloat", .{ .native = &parse_float_global } },
    .{ "isNaN", .{ .native = &is_nan_global } },
    .{ "isFinite", .{ .native = &is_finite_global } },
    .{ "encodeURI", .{ .native = &encode_uri_global } },
    .{ "decodeURI", .{ .native = &decode_uri_global } },
    .{ "encodeURIComponent", .{ .native = &encode_uri_component_global } },
    .{ "decodeURIComponent", .{ .native = &decode_uri_component_global } },
    .{ "Map", .{ .native = &map_global } },
    .{ "Set", .{ .native = &set_global } },
    .{ "WeakMap", .{ .native = &weak_map_global } },
    .{ "WeakSet", .{ .native = &weak_set_global } },
    .{ "Iterator", .{ .native = &iterator_global } },
    .{ "Proxy", .{ .native = &proxy_global } },
    .{ "Reflect", .reflect },
    .{ "Promise", .{ .native = &promise_global } },
    .{ "Error", .{ .native = &error_global } },
    .{ "TypeError", .{ .native = &type_error_global } },
    .{ "RangeError", .{ .native = &range_error_global } },
    .{ "SyntaxError", .{ .native = &syntax_error_global } },
    .{ "ReferenceError", .{ .native = &reference_error_global } },
    .{ "EvalError", .{ .native = &eval_error_global } },
    .{ "URIError", .{ .native = &uri_error_global } },
    .{ "AggregateError", .{ .native = &aggregate_error_global } },
    .{ "RegExp", .{ .native = &regexp_global } },
    .{ "Date", .{ .native = &date_global } },
    .{ "Symbol", .{ .native = &symbol_global } },
    .{ "BigInt", .{ .native = &bigint_global } },
    .{ "ArrayBuffer", .{ .native = &array_buffer_global } },
    .{ "DataView", .{ .native = &data_view_global } },
    .{ "Int8Array", .{ .native = &typed_array_ctors[0] } },
    .{ "Uint8Array", .{ .native = &typed_array_ctors[1] } },
    .{ "Uint8ClampedArray", .{ .native = &typed_array_ctors[2] } },
    .{ "Int16Array", .{ .native = &typed_array_ctors[3] } },
    .{ "Uint16Array", .{ .native = &typed_array_ctors[4] } },
    .{ "Int32Array", .{ .native = &typed_array_ctors[5] } },
    .{ "Uint32Array", .{ .native = &typed_array_ctors[6] } },
    .{ "Float32Array", .{ .native = &typed_array_ctors[7] } },
    .{ "Float64Array", .{ .native = &typed_array_ctors[8] } },
    .{ "BigInt64Array", .{ .native = &typed_array_ctors[9] } },
    .{ "BigUint64Array", .{ .native = &typed_array_ctors[10] } },
    .{ "Math", .math },
    .{ "JSON", .json },
    .{ "console", .console },
    .{ "structuredClone", .{ .native = &structured_clone_global } },
    .{ "atob", .{ .native = &atob_global } },
    .{ "btoa", .{ .native = &btoa_global } },
    .{ "TextEncoder", .{ .native = &text_encoder_global } },
    .{ "TextDecoder", .{ .native = &text_decoder_global } },
});

pub inline fn realmIfInit(rt: *const Runtime) ?*const Realm {
    return if (rt.realm) |*r| r else null;
}

pub inline fn resolveGlobalTargetByIndex(r: *const Realm, idx: u16) Value {
    return switch (builtin_globals.values()[idx]) {
        .undefined => .undefined,
        .nan => Value.fromNumber(std.math.nan(f64)),
        .inf => Value.fromNumber(std.math.inf(f64)),
        .math => Value.fromObject(r.math),
        .json => Value.fromObject(r.json),
        .console => Value.fromObject(r.console),
        .reflect => Value.fromObject(r.reflect),
        .global_this => Value.fromObject(r.global_object),
        .native => |n| Value.fromNative(n),
    };
}

fn resolveGlobalTarget(rt: *Runtime, target: GlobalTarget) Error!Value {
    return switch (target) {
        .undefined => .undefined,
        .nan => Value.fromNumber(std.math.nan(f64)),
        .inf => Value.fromNumber(std.math.inf(f64)),
        .math => Value.fromObject((try realm(rt)).math),
        .json => Value.fromObject((try realm(rt)).json),
        .console => Value.fromObject((try realm(rt)).console),
        .reflect => Value.fromObject((try realm(rt)).reflect),
        .global_this => Value.fromObject((try realm(rt)).global_object),
        .native => |n| Value.fromNative(n),
    };
}

fn lookupGlobal(rt: *Runtime, name: []const u8) Error!?Value {
    if (rt.realm) |r| {
        const k = try object.named(rt, name);
        if (r.global_object.props.get(try object.propKey(rt, k))) |p| {
            if (p.is_accessor) {
                if (p.value.isUndefined()) return .undefined;
                return try rt.callCallable(p.value, Value.fromObject(r.global_object), &.{});
            }
            return p.value;
        }
    } else if (builtin_globals.get(name)) |target| {
        return try resolveGlobalTarget(rt, target);
    }
    for (rt.host_globals.items) |n| if (std.mem.eql(u8, n.name, name)) return Value.fromNative(n);
    if (names.has(.global, name) and !builtin_globals.has(name)) {
        rt.unsupported_name = try rt.heap.internAscii(name);
        return rt.fail(.builtin);
    }
    return null;
}

pub fn defineGlobalVar(rt: *Runtime, name: []const u8) Error!void {
    const r = try realm(rt);
    const k = try object.named(rt, name);
    const pk = try object.propKey(rt, k);
    if (r.global_object.props.get(pk) != null) return;
    if (!r.global_object.extensible) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot define property on non-extensible global object" }});
    }
    try rt.heap.definePropKey(r.global_object, pk, .{
        .value = .undefined,
        .writable = true,
        .enumerable = true,
        .configurable = false,
    });
}

pub fn setGlobal(rt: *Runtime, name: []const u8, val: Value, strict: bool) Error!void {
    const r = try realm(rt);
    var root_buf = [_]Value{val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const k = try object.named(rt, name);
    var exists = r.global_object.props.get(try object.propKey(rt, k)) != null;
    if (!exists) {
        for (rt.host_globals.items) |n| {
            if (std.mem.eql(u8, n.name, name)) {
                exists = true;
                break;
            }
        }
    }
    if (!exists and strict) {
        return rt.throw(.ReferenceError, &.{ .{ .ascii = name }, .{ .ascii = " is not defined" } });
    }
    _ = try object.setWithReceiver(rt, Value.fromObject(r.global_object), k, val, Value.fromObject(r.global_object), strict);
}

pub fn coerceThis(rt: *Runtime, raw: ?Value, is_strict: bool) Error!?Value {
    const v: Value = raw orelse .undefined;
    if (is_strict) return v;
    if (v.isUndefined() or v.isNull()) return null; // requireThis lazily resolves to globalThis
    if (v.isObjectLike()) return v;
    return try common.toObjectReceiver(rt, v);
}

pub fn isImplementedGlobal(name: []const u8) bool {
    return builtin_globals.has(name);
}

pub fn globalOwnProp(rt: *Runtime, atom: *const heap_mod.String) Error!?heap_mod.Property {
    if (atom.units.len > 64) return null;
    var buf: [64]u8 = undefined;
    for (atom.units, 0..) |u, i| {
        if (u > 0x7f) return null;
        buf[i] = @intCast(u);
    }
    const name = buf[0..atom.units.len];
    for (rt.host_globals.items) |n| if (std.mem.eql(u8, n.name, name)) {
        return .{
            .value = Value.fromNative(n),
            .enumerable = false,
            .writable = true,
            .configurable = true,
        };
    };
    return null;
}

/// Whether `name` is already a built-in or node-known global name (D53: duplicate
/// registration is rejected, including built-in names).
pub fn isBuiltinGlobal(name: []const u8) bool {
    return builtin_globals.has(name) or names.has(.global, name);
}

/// Evaluates `new callee(args...)` for built-in constructors (M14).
pub fn construct(rt: *Runtime, callee: Value, args: []const Value) Error!Value {
    return switch (callee.unpack()) {
        .native => |n| if (n.construct) |c| c(rt, args) else if (n == &symbol_global or n == &bigint_global) rt.throw(.TypeError, &.{ .{ .ascii = n.name }, .{ .ascii = " is not a constructor" } }) else if (n.namespace != null) rt.fail(.builtin) else rt.throw(.TypeError, &.{ .{ .ascii = n.name }, .{ .ascii = " is not a constructor" } }),
        .closure => rt.fail(.builtin),
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }}),
    };
}
