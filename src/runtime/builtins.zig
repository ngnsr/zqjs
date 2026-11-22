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
const coroutine = @import("coroutine.zig");
const clone = @import("clone.zig");
const Runtime = rt_mod.Runtime;
const Error = rt_mod.Error;
const ops = @import("ops.zig");
const bigint = @import("bigint.zig");
const object = @import("object.zig");
const names = @import("builtin_names.zig");
const json = @import("json.zig");
const date = @import("date.zig");
const regex = @import("../regex.zig");
const Feature = @import("../frontend/diag.zig").Feature;
const ast = @import("../frontend/ast.zig");
const bytecode = @import("../bytecode/bytecode.zig");

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
    global_object: *Object,
    views: ?ViewsRealm = null,

    /// For GC roots (M8) and tests.
    pub fn objects(r: *const Realm) [62]*Object {
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
    const object_prototype = try builtin(h, null, .object_prototype);
    const error_prototype = try builtin(h, object_prototype, .error_prototype);
    const iterator_prototype = try builtin(h, object_prototype, .iterator_prototype);
    const async_iterator_prototype = try builtin(h, object_prototype, .async_iterator_prototype);
    const function_prototype = try builtin(h, object_prototype, .function_prototype);
    var r: Realm = .{
        .object_prototype = object_prototype,
        .array_prototype = try builtin(h, object_prototype, .array_prototype),
        .string_prototype = try builtin(h, object_prototype, .string_prototype),
        .number_prototype = try builtin(h, object_prototype, .number_prototype),
        .boolean_prototype = try builtin(h, object_prototype, .boolean_prototype),
        .function_prototype = function_prototype,
        .function_namespace = try builtin(h, null, .function_constructor),
        .map_prototype = try builtin(h, object_prototype, .map_prototype),
        .set_prototype = try builtin(h, object_prototype, .set_prototype),
        .weak_map_prototype = try builtin(h, object_prototype, .weak_map_prototype),
        .weak_set_prototype = try builtin(h, object_prototype, .weak_set_prototype),
        .promise_prototype = try builtin(h, object_prototype, .promise_prototype),
        .iterator_namespace = try h.newObject(function_prototype),
        .iterator_prototype = iterator_prototype,
        .iterator_helper_prototype = try h.newObject(iterator_prototype),
        .iterator_wrap_prototype = try h.newObject(iterator_prototype),
        .generator_prototype = try builtin(h, iterator_prototype, .generator_prototype),
        .async_iterator_prototype = async_iterator_prototype,
        .async_generator_prototype = try builtin(h, async_iterator_prototype, .async_generator_prototype),
        .async_from_sync_iterator_prototype = try h.newObject(async_iterator_prototype),
        .generator_function_prototype = try builtin(h, function_prototype, .generator_function_prototype),
        .async_generator_function_prototype = try builtin(h, function_prototype, .async_generator_function_prototype),
        .async_function_prototype = try builtin(h, function_prototype, .async_function_prototype),
        .error_prototype = error_prototype,
        .type_error_prototype = try builtin(h, error_prototype, .type_error_prototype),
        .range_error_prototype = try builtin(h, error_prototype, .range_error_prototype),
        .syntax_error_prototype = try builtin(h, error_prototype, .syntax_error_prototype),
        .reference_error_prototype = try builtin(h, error_prototype, .reference_error_prototype),
        .eval_error_prototype = try builtin(h, error_prototype, .eval_error_prototype),
        .uri_error_prototype = try builtin(h, error_prototype, .uri_error_prototype),
        .aggregate_error_prototype = try builtin(h, error_prototype, .aggregate_error_prototype),
        .regexp_prototype = try builtin(h, object_prototype, .regexp_prototype),
        .date_prototype = try builtin(h, object_prototype, .date_prototype),
        .object_namespace = try builtin(h, null, .object_constructor),
        .array_namespace = try builtin(h, null, .array_constructor),
        .string_namespace = try builtin(h, null, .string_constructor),
        .number_namespace = try builtin(h, null, .number_constructor),
        .boolean_namespace = try h.newObject(null),
        .map_namespace = try builtin(h, null, .map_constructor),
        .set_namespace = try builtin(h, null, .set_constructor),
        .weak_map_namespace = try builtin(h, null, .weak_map_constructor),
        .weak_set_namespace = try builtin(h, null, .weak_set_constructor),
        .proxy_namespace = try builtin(h, null, .proxy_constructor),
        .reflect = try builtin(h, object_prototype, .reflect),
        .promise_namespace = try builtin(h, null, .promise_constructor),
        .error_namespace = try builtin(h, null, .error_constructor),
        .type_error_namespace = try builtin(h, null, .type_error_constructor),
        .range_error_namespace = try builtin(h, null, .range_error_constructor),
        .syntax_error_namespace = try builtin(h, null, .syntax_error_constructor),
        .reference_error_namespace = try builtin(h, null, .reference_error_constructor),
        .eval_error_namespace = try builtin(h, null, .eval_error_constructor),
        .uri_error_namespace = try builtin(h, null, .uri_error_constructor),
        .aggregate_error_namespace = try builtin(h, null, .aggregate_error_constructor),
        .regexp_namespace = try builtin(h, null, .regexp_constructor),
        .date_namespace = try builtin(h, null, .date_constructor),
        .symbol_prototype = try builtin(h, object_prototype, .symbol_prototype),
        .symbol_namespace = try builtin(h, null, .symbol_constructor),
        .bigint_prototype = try builtin(h, object_prototype, .bigint_prototype),
        .bigint_namespace = try builtin(h, null, .bigint_constructor),
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
        .math = try builtin(h, object_prototype, .math),
        .json = try builtin(h, object_prototype, .json),
        .global_object = try builtin(h, object_prototype, .global),
    };
    try method(rt, r.object_prototype, "toString", &object_to_string);
    try method(rt, r.object_prototype, "valueOf", &object_value_of);
    try method(rt, r.object_prototype, "hasOwnProperty", &object_proto_has_own_property);
    try method(rt, r.object_prototype, "isPrototypeOf", &object_proto_is_prototype_of);
    try method(rt, r.object_prototype, "propertyIsEnumerable", &object_proto_property_is_enumerable);
    try method(rt, r.array_prototype, "push", &array_push);
    try method(rt, r.array_prototype, "pop", &array_pop);
    try method(rt, r.array_prototype, "slice", &array_slice);
    try method(rt, r.array_prototype, "indexOf", &array_index_of);
    try method(rt, r.array_prototype, "includes", &array_includes);
    try method(rt, r.array_prototype, "join", &array_join);
    try method(rt, r.array_prototype, "toString", &array_to_string);
    try method(rt, r.array_prototype, "keys", &array_keys);
    try method(rt, r.array_prototype, "values", &array_values);
    try method(rt, r.array_prototype, "entries", &array_entries);
    try method(rt, r.array_prototype, "forEach", &array_for_each);
    try method(rt, r.array_prototype, "map", &array_map);
    try method(rt, r.array_prototype, "filter", &array_filter);
    try method(rt, r.array_prototype, "reduce", &array_reduce);
    try method(rt, r.array_prototype, "find", &array_find);
    try method(rt, r.array_prototype, "findIndex", &array_find_index);
    try method(rt, r.array_prototype, "findLast", &array_find_last);
    try method(rt, r.array_prototype, "findLastIndex", &array_find_last_index);
    try method(rt, r.array_prototype, "some", &array_some);
    try method(rt, r.array_prototype, "every", &array_every);
    try method(rt, r.array_prototype, "concat", &array_concat);
    try method(rt, r.array_prototype, "reverse", &array_reverse);
    try method(rt, r.array_prototype, "at", &array_at);
    try method(rt, r.array_prototype, "lastIndexOf", &array_last_index_of);
    try method(rt, r.array_prototype, "fill", &array_fill);
    try method(rt, r.array_prototype, "shift", &array_shift);
    try method(rt, r.array_prototype, "unshift", &array_unshift);
    try method(rt, r.array_prototype, "splice", &array_splice);
    try method(rt, r.array_prototype, "sort", &array_sort);
    try method(rt, r.array_prototype, "reduceRight", &array_reduce_right);
    try method(rt, r.array_prototype, "flat", &array_flat);
    try method(rt, r.array_prototype, "flatMap", &array_flat_map);
    try method(rt, r.array_prototype, "copyWithin", &array_copy_within);
    try method(rt, r.array_prototype, "toReversed", &array_to_reversed);
    try method(rt, r.array_prototype, "toSorted", &array_to_sorted);
    try method(rt, r.array_prototype, "toSpliced", &array_to_spliced);
    try method(rt, r.array_prototype, "with", &array_with);
    try method(rt, r.string_prototype, "charAt", &string_char_at);
    try method(rt, r.string_prototype, "charCodeAt", &string_char_code_at);
    try method(rt, r.string_prototype, "slice", &string_slice);
    try method(rt, r.string_prototype, "indexOf", &string_index_of);
    try method(rt, r.string_prototype, "includes", &string_includes);
    try method(rt, r.string_prototype, "toLowerCase", &string_to_lower_case);
    try method(rt, r.string_prototype, "toUpperCase", &string_to_upper_case);
    try method(rt, r.string_prototype, "toLocaleLowerCase", &string_to_locale_lower_case);
    try method(rt, r.string_prototype, "toLocaleUpperCase", &string_to_locale_upper_case);
    try method(rt, r.string_prototype, "concat", &string_concat);
    try method(rt, r.string_prototype, "split", &string_split);
    try method(rt, r.string_prototype, "trim", &string_trim);
    try method(rt, r.string_prototype, "trimStart", &string_trim_start);
    try method(rt, r.string_prototype, "trimEnd", &string_trim_end);
    try method(rt, r.string_prototype, "startsWith", &string_starts_with);
    try method(rt, r.string_prototype, "endsWith", &string_ends_with);
    try method(rt, r.string_prototype, "repeat", &string_repeat);
    try method(rt, r.string_prototype, "padStart", &string_pad_start);
    try method(rt, r.string_prototype, "padEnd", &string_pad_end);
    try method(rt, r.string_prototype, "substring", &string_substring);
    try method(rt, r.string_prototype, "lastIndexOf", &string_last_index_of);
    try method(rt, r.string_prototype, "at", &string_at);
    try method(rt, r.string_prototype, "replace", &string_replace);
    try method(rt, r.string_prototype, "replaceAll", &string_replace_all);
    try method(rt, r.string_prototype, "match", &string_match);
    try method(rt, r.string_prototype, "matchAll", &string_match_all);
    try method(rt, r.string_prototype, "search", &string_search);
    try method(rt, r.string_prototype, "codePointAt", &string_code_point_at);
    try method(rt, r.string_namespace, "fromCharCode", &string_from_char_code);
    try method(rt, r.string_namespace, "fromCodePoint", &string_from_code_point);
    try method(rt, r.string_namespace, "raw", &string_raw);
    try method(rt, r.object_namespace, "keys", &object_keys);
    try method(rt, r.object_namespace, "values", &object_values);
    try method(rt, r.object_namespace, "entries", &object_entries);
    try method(rt, r.object_namespace, "assign", &object_assign);
    try method(rt, r.object_namespace, "create", &object_create);
    try method(rt, r.object_namespace, "getPrototypeOf", &object_get_prototype_of);
    try method(rt, r.object_namespace, "defineProperty", &object_define_property);
    try method(rt, r.object_namespace, "defineProperties", &object_define_properties);
    try method(rt, r.object_namespace, "getOwnPropertyDescriptor", &object_get_own_property_descriptor);
    try method(rt, r.object_namespace, "getOwnPropertyDescriptors", &object_get_own_property_descriptors);
    try method(rt, r.object_namespace, "getOwnPropertySymbols", &object_get_own_property_symbols);
    try method(rt, r.object_namespace, "getOwnPropertyNames", &object_get_own_property_names);
    try method(rt, r.object_namespace, "setPrototypeOf", &object_set_prototype_of);
    try method(rt, r.object_namespace, "preventExtensions", &object_prevent_extensions);
    try method(rt, r.object_namespace, "isExtensible", &object_is_extensible);
    try method(rt, r.object_namespace, "seal", &object_seal);
    try method(rt, r.object_namespace, "isSealed", &object_is_sealed);
    try method(rt, r.object_namespace, "freeze", &object_freeze);
    try method(rt, r.object_namespace, "isFrozen", &object_is_frozen);
    try method(rt, r.object_namespace, "hasOwn", &object_has_own);
    try method(rt, r.object_namespace, "is", &object_is);
    try method(rt, r.object_namespace, "fromEntries", &object_from_entries);
    try method(rt, r.object_namespace, "groupBy", &object_group_by);
    try method(rt, r.map_namespace, "groupBy", &map_group_by);
    try method(rt, r.array_namespace, "isArray", &array_is_array);
    try method(rt, r.array_namespace, "from", &array_from);
    try method(rt, r.array_namespace, "fromAsync", &array_from_async);
    try method(rt, r.array_namespace, "of", &array_of);
    try method(rt, r.number_namespace, "isInteger", &number_is_integer);
    try method(rt, r.number_namespace, "isFinite", &number_is_finite);
    try method(rt, r.number_namespace, "isNaN", &number_is_nan);
    try method(rt, r.number_namespace, "isSafeInteger", &number_is_safe_integer);
    try immutableConstant(rt, r.number_namespace, "MAX_SAFE_INTEGER", Value.fromNumber(9007199254740991.0));
    try immutableConstant(rt, r.number_namespace, "MIN_SAFE_INTEGER", Value.fromNumber(-9007199254740991.0));
    try immutableConstant(rt, r.number_namespace, "EPSILON", Value.fromNumber(std.math.floatEps(f64)));
    try immutableConstant(rt, r.number_namespace, "MAX_VALUE", Value.fromNumber(std.math.floatMax(f64)));
    try immutableConstant(rt, r.number_namespace, "MIN_VALUE", Value.fromNumber(std.math.floatTrueMin(f64)));
    try immutableConstant(rt, r.number_namespace, "POSITIVE_INFINITY", Value.fromNumber(std.math.inf(f64)));
    try immutableConstant(rt, r.number_namespace, "NEGATIVE_INFINITY", Value.fromNumber(-std.math.inf(f64)));
    try immutableConstant(rt, r.number_namespace, "NaN", Value.fromNumber(std.math.nan(f64)));
    try method(rt, r.proxy_namespace, "revocable", &proxy_revocable);
    try defineToStringTag(rt, r.reflect, r.sym_to_string_tag, "Reflect");
    try method(rt, r.reflect, "get", &reflect_get);
    try method(rt, r.reflect, "set", &reflect_set);
    try method(rt, r.reflect, "has", &reflect_has);
    try method(rt, r.reflect, "deleteProperty", &reflect_delete_property);
    try method(rt, r.reflect, "ownKeys", &reflect_own_keys);
    try method(rt, r.reflect, "getOwnPropertyDescriptor", &reflect_get_own_property_descriptor);
    try method(rt, r.reflect, "defineProperty", &reflect_define_property);
    try method(rt, r.reflect, "getPrototypeOf", &reflect_get_prototype_of);
    try method(rt, r.reflect, "setPrototypeOf", &reflect_set_prototype_of);
    try method(rt, r.reflect, "isExtensible", &reflect_is_extensible);
    try method(rt, r.reflect, "preventExtensions", &reflect_prevent_extensions);
    try method(rt, r.reflect, "apply", &reflect_apply);
    try method(rt, r.reflect, "construct", &reflect_construct);
    try method(rt, r.map_prototype, "get", &map_get);
    try method(rt, r.map_prototype, "set", &map_set);
    try method(rt, r.map_prototype, "has", &map_has);
    try method(rt, r.map_prototype, "delete", &map_delete);
    try method(rt, r.map_prototype, "clear", &map_clear);
    try method(rt, r.map_prototype, "keys", &map_keys);
    try method(rt, r.map_prototype, "values", &map_values);
    try method(rt, r.map_prototype, "entries", &map_entries);
    try method(rt, r.map_prototype, "forEach", &map_for_each);
    try method(rt, r.set_prototype, "add", &set_add);
    try method(rt, r.set_prototype, "has", &set_has);
    try method(rt, r.set_prototype, "delete", &set_delete);
    try method(rt, r.set_prototype, "clear", &set_clear);
    try method(rt, r.set_prototype, "keys", &set_values);
    try method(rt, r.set_prototype, "values", &set_values);
    try method(rt, r.set_prototype, "entries", &set_entries);
    try method(rt, r.set_prototype, "forEach", &set_for_each);
    try method(rt, r.set_prototype, "union", &set_union);
    try method(rt, r.set_prototype, "intersection", &set_intersection);
    try method(rt, r.set_prototype, "difference", &set_difference);
    try method(rt, r.set_prototype, "symmetricDifference", &set_symmetric_difference);
    try method(rt, r.set_prototype, "isSubsetOf", &set_is_subset_of);
    try method(rt, r.set_prototype, "isSupersetOf", &set_is_superset_of);
    try method(rt, r.set_prototype, "isDisjointFrom", &set_is_disjoint_from);
    try constant(rt, r.weak_map_prototype, "constructor", Value.fromNative(&weak_map_global));
    try method(rt, r.weak_map_prototype, "get", &weak_map_get);
    try method(rt, r.weak_map_prototype, "set", &weak_map_set);
    try method(rt, r.weak_map_prototype, "has", &weak_map_has);
    try method(rt, r.weak_map_prototype, "delete", &weak_map_delete);
    try constant(rt, r.weak_set_prototype, "constructor", Value.fromNative(&weak_set_global));
    try method(rt, r.weak_set_prototype, "add", &weak_set_add);
    try method(rt, r.weak_set_prototype, "has", &weak_set_has);
    try method(rt, r.weak_set_prototype, "delete", &weak_set_delete);
    try method(rt, r.promise_prototype, "then", &promise_then);
    try method(rt, r.promise_prototype, "catch", &promise_catch);
    try method(rt, r.promise_prototype, "finally", &promise_finally);
    try method(rt, r.promise_namespace, "resolve", &promise_resolve_static);
    try method(rt, r.promise_namespace, "reject", &promise_reject_static);
    try method(rt, r.promise_namespace, "all", &promise_all_static);
    try method(rt, r.promise_namespace, "allSettled", &promise_all_settled_static);
    try method(rt, r.promise_namespace, "race", &promise_race_static);
    try method(rt, r.promise_namespace, "any", &promise_any_static);
    try method(rt, r.promise_namespace, "withResolvers", &promise_with_resolvers_static);
    try method(rt, r.promise_namespace, "try", &promise_try_static);
    try method(rt, r.iterator_prototype, "next", &iterator_next);
    try symbolMethod(rt, r.array_prototype, r.sym_iterator, &array_values);
    try symbolMethod(rt, r.string_prototype, r.sym_iterator, &string_iterator);
    try symbolMethod(rt, r.map_prototype, r.sym_iterator, &map_entries);
    try symbolMethod(rt, r.set_prototype, r.sym_iterator, &set_values);
    try symbolMethod(rt, r.iterator_prototype, r.sym_iterator, &iterator_self);
    try immutableConstant(rt, r.iterator_namespace, "prototype", Value.fromObject(r.iterator_prototype));
    try method(rt, r.iterator_namespace, "from", &iterator_from);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), try object.named(rt, "constructor"), Value.fromNative(&iterator_proto_ctor_get), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), try object.named(rt, "constructor"), Value.fromNative(&iterator_proto_ctor_set), true, false);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), .{ .symbol = r.sym_to_string_tag }, Value.fromNative(&iterator_proto_tag_get), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.iterator_prototype), .{ .symbol = r.sym_to_string_tag }, Value.fromNative(&iterator_proto_tag_set), true, false);
    try method(rt, r.iterator_prototype, "map", &iterator_map);
    try method(rt, r.iterator_prototype, "filter", &iterator_filter);
    try method(rt, r.iterator_prototype, "take", &iterator_take);
    try method(rt, r.iterator_prototype, "drop", &iterator_drop);
    try method(rt, r.iterator_prototype, "flatMap", &iterator_flat_map);
    try method(rt, r.iterator_prototype, "reduce", &iterator_reduce);
    try method(rt, r.iterator_prototype, "toArray", &iterator_to_array);
    try method(rt, r.iterator_prototype, "forEach", &iterator_for_each);
    try method(rt, r.iterator_prototype, "some", &iterator_some);
    try method(rt, r.iterator_prototype, "every", &iterator_every);
    try method(rt, r.iterator_prototype, "find", &iterator_find);
    try method(rt, r.iterator_helper_prototype, "next", &iterator_helper_next);
    try method(rt, r.iterator_helper_prototype, "return", &iterator_helper_return);
    try defineToStringTag(rt, r.iterator_helper_prototype, r.sym_to_string_tag, "Iterator Helper");
    try method(rt, r.iterator_wrap_prototype, "next", &iterator_wrap_next);
    try method(rt, r.iterator_wrap_prototype, "return", &iterator_wrap_return);
    try method(rt, r.generator_prototype, "next", &generator_next);
    try method(rt, r.generator_prototype, "return", &generator_return);
    try method(rt, r.generator_prototype, "throw", &generator_throw);
    try symbolMethod(rt, r.async_iterator_prototype, r.sym_async_iterator, &async_iterator_self);
    try method(rt, r.async_generator_prototype, "next", &async_generator_next);
    try method(rt, r.async_generator_prototype, "return", &async_generator_return);
    try method(rt, r.async_generator_prototype, "throw", &async_generator_throw);
    try method(rt, r.async_from_sync_iterator_prototype, "next", &async_from_sync_next);
    try method(rt, r.async_from_sync_iterator_prototype, "return", &async_from_sync_return);
    try method(rt, r.async_from_sync_iterator_prototype, "throw", &async_from_sync_throw);
    // %GeneratorFunction.prototype%.prototype ⇄ %GeneratorPrototype%.constructor (and the
    // async pair); both non-writable and non-enumerable, as in node (D68).
    try link(rt, r.generator_function_prototype, "prototype", r.generator_prototype);
    try link(rt, r.generator_prototype, "constructor", r.generator_function_prototype);
    try link(rt, r.async_generator_function_prototype, "prototype", r.async_generator_prototype);
    try link(rt, r.async_generator_prototype, "constructor", r.async_generator_function_prototype);
    try registerMath(rt, r.math);
    try method(rt, r.json, "parse", &json.parse_native);
    try method(rt, r.json, "stringify", &json.stringify_native);
    try initErrorProto(rt, r.error_prototype, r.error_namespace, "Error", &error_global);
    try method(rt, r.error_namespace, "isError", &error_is_error);
    try method(rt, r.error_prototype, "toString", &error_to_string);
    try initErrorProto(rt, r.type_error_prototype, r.type_error_namespace, "TypeError", &type_error_global);
    try initErrorProto(rt, r.range_error_prototype, r.range_error_namespace, "RangeError", &range_error_global);
    try initErrorProto(rt, r.syntax_error_prototype, r.syntax_error_namespace, "SyntaxError", &syntax_error_global);
    try initErrorProto(rt, r.reference_error_prototype, r.reference_error_namespace, "ReferenceError", &reference_error_global);
    try initErrorProto(rt, r.eval_error_prototype, r.eval_error_namespace, "EvalError", &eval_error_global);
    try initErrorProto(rt, r.uri_error_prototype, r.uri_error_namespace, "URIError", &uri_error_global);
    try initErrorProto(rt, r.aggregate_error_prototype, r.aggregate_error_namespace, "AggregateError", &aggregate_error_global);
    try immutableConstant(rt, r.regexp_namespace, "prototype", Value.fromObject(r.regexp_prototype));
    try constant(rt, r.regexp_prototype, "constructor", Value.fromNative(&regexp_global));
    try method(rt, r.regexp_namespace, "escape", &regexp_escape);
    try method(rt, r.regexp_prototype, "exec", &regexp_exec);
    try method(rt, r.regexp_prototype, "test", &regexp_test);
    try method(rt, r.regexp_prototype, "toString", &regexp_to_string);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "source"), Value.fromNative(&regexp_source_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "flags"), Value.fromNative(&regexp_flags_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "hasIndices"), Value.fromNative(&regexp_has_indices_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "global"), Value.fromNative(&regexp_global_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "ignoreCase"), Value.fromNative(&regexp_ignore_case_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "multiline"), Value.fromNative(&regexp_multiline_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "dotAll"), Value.fromNative(&regexp_dot_all_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "unicode"), Value.fromNative(&regexp_unicode_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "unicodeSets"), Value.fromNative(&regexp_unicode_sets_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_prototype), try object.named(rt, "sticky"), Value.fromNative(&regexp_sticky_getter), false, false);
    try immutableConstant(rt, r.date_namespace, "prototype", Value.fromObject(r.date_prototype));
    try method(rt, r.date_namespace, "now", &date_now);
    try method(rt, r.date_namespace, "UTC", &date_utc);
    try method(rt, r.date_namespace, "parse", &date_parse);
    try constant(rt, r.date_prototype, "constructor", Value.fromNative(&date_global));
    try method(rt, r.date_prototype, "getTime", &date_get_time);
    try method(rt, r.date_prototype, "valueOf", &date_value_of);
    try method(rt, r.date_prototype, "getTimezoneOffset", &date_get_timezone_offset);
    try method(rt, r.date_prototype, "setTime", &date_set_time);
    try method(rt, r.date_prototype, "getUTCFullYear", &date_get_utc_full_year);
    try method(rt, r.date_prototype, "getUTCMonth", &date_get_utc_month);
    try method(rt, r.date_prototype, "getUTCDate", &date_get_utc_date);
    try method(rt, r.date_prototype, "getUTCDay", &date_get_utc_day);
    try method(rt, r.date_prototype, "getUTCHours", &date_get_utc_hours);
    try method(rt, r.date_prototype, "getUTCMinutes", &date_get_utc_minutes);
    try method(rt, r.date_prototype, "getUTCSeconds", &date_get_utc_seconds);
    try method(rt, r.date_prototype, "getUTCMilliseconds", &date_get_utc_milliseconds);
    try method(rt, r.date_prototype, "setUTCFullYear", &date_set_utc_full_year);
    try method(rt, r.date_prototype, "setUTCMonth", &date_set_utc_month);
    try method(rt, r.date_prototype, "setUTCDate", &date_set_utc_date);
    try method(rt, r.date_prototype, "setUTCHours", &date_set_utc_hours);
    try method(rt, r.date_prototype, "setUTCMinutes", &date_set_utc_minutes);
    try method(rt, r.date_prototype, "setUTCSeconds", &date_set_utc_seconds);
    try method(rt, r.date_prototype, "setUTCMilliseconds", &date_set_utc_milliseconds);
    try method(rt, r.date_prototype, "getFullYear", &date_get_full_year);
    try method(rt, r.date_prototype, "getMonth", &date_get_month);
    try method(rt, r.date_prototype, "getDate", &date_get_date);
    try method(rt, r.date_prototype, "getDay", &date_get_day);
    try method(rt, r.date_prototype, "getHours", &date_get_hours);
    try method(rt, r.date_prototype, "getMinutes", &date_get_minutes);
    try method(rt, r.date_prototype, "getSeconds", &date_get_seconds);
    try method(rt, r.date_prototype, "getMilliseconds", &date_get_milliseconds);
    try method(rt, r.date_prototype, "setFullYear", &date_set_full_year);
    try method(rt, r.date_prototype, "setMonth", &date_set_month);
    try method(rt, r.date_prototype, "setDate", &date_set_date);
    try method(rt, r.date_prototype, "setHours", &date_set_hours);
    try method(rt, r.date_prototype, "setMinutes", &date_set_minutes);
    try method(rt, r.date_prototype, "setSeconds", &date_set_seconds);
    try method(rt, r.date_prototype, "setMilliseconds", &date_set_milliseconds);
    try method(rt, r.date_prototype, "toISOString", &date_to_iso_string);
    try method(rt, r.date_prototype, "toUTCString", &date_to_utc_string);
    try method(rt, r.date_prototype, "toString", &date_to_string);
    try method(rt, r.date_prototype, "toDateString", &date_to_date_string);
    try method(rt, r.date_prototype, "toTimeString", &date_to_time_string);
    try method(rt, r.date_prototype, "toJSON", &date_to_json);
    try rt.heap.definePropKey(r.date_prototype, heap_mod.PropKey.fromSymbol(r.sym_to_primitive), .{
        .value = Value.fromNative(&date_to_primitive),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
    try immutableConstant(rt, r.function_namespace, "prototype", Value.fromObject(r.function_prototype));
    try constant(rt, r.function_prototype, "constructor", Value.fromNative(&function_global));
    try immutableConstant(rt, r.object_namespace, "prototype", Value.fromObject(r.object_prototype));
    try constant(rt, r.object_prototype, "constructor", Value.fromNative(&object_global));
    try immutableConstant(rt, r.array_namespace, "prototype", Value.fromObject(r.array_prototype));
    try constant(rt, r.array_prototype, "constructor", Value.fromNative(&array_global));
    try immutableConstant(rt, r.string_namespace, "prototype", Value.fromObject(r.string_prototype));
    try constant(rt, r.string_prototype, "constructor", Value.fromNative(&string_global));
    try method(rt, r.string_prototype, "toString", &string_to_string);
    try method(rt, r.string_prototype, "valueOf", &string_value_of);
    try immutableConstant(rt, r.number_namespace, "prototype", Value.fromObject(r.number_prototype));
    try constant(rt, r.number_prototype, "constructor", Value.fromNative(&number_global));
    try method(rt, r.number_prototype, "toString", &number_to_string);
    try method(rt, r.number_prototype, "toFixed", &number_to_fixed);
    try method(rt, r.number_prototype, "toExponential", &number_to_exponential);
    try method(rt, r.number_prototype, "toPrecision", &number_to_precision);
    try method(rt, r.number_prototype, "toLocaleString", &number_to_locale_string);
    try method(rt, r.number_prototype, "valueOf", &number_value_of);
    try immutableConstant(rt, r.boolean_namespace, "prototype", Value.fromObject(r.boolean_prototype));
    try constant(rt, r.boolean_prototype, "constructor", Value.fromNative(&boolean_global));
    try method(rt, r.boolean_prototype, "toString", &boolean_to_string);
    try method(rt, r.boolean_prototype, "valueOf", &boolean_value_of);
    try immutableConstant(rt, r.map_namespace, "prototype", Value.fromObject(r.map_prototype));
    try constant(rt, r.map_prototype, "constructor", Value.fromNative(&map_global));
    try immutableConstant(rt, r.set_namespace, "prototype", Value.fromObject(r.set_prototype));
    try constant(rt, r.set_prototype, "constructor", Value.fromNative(&set_global));
    try immutableConstant(rt, r.weak_map_namespace, "prototype", Value.fromObject(r.weak_map_prototype));
    try immutableConstant(rt, r.weak_set_namespace, "prototype", Value.fromObject(r.weak_set_prototype));
    try immutableConstant(rt, r.promise_namespace, "prototype", Value.fromObject(r.promise_prototype));
    try constant(rt, r.promise_prototype, "constructor", Value.fromNative(&promise_global));
    try method(rt, r.function_prototype, "call", &function_call);
    try method(rt, r.function_prototype, "apply", &function_apply);
    try method(rt, r.function_prototype, "bind", &function_bind);
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(r.symbol_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("iterator"), .{
        .value = Value.fromSymbol(r.sym_iterator),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("asyncIterator"), .{
        .value = Value.fromSymbol(r.sym_async_iterator),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("toPrimitive"), .{
        .value = Value.fromSymbol(r.sym_to_primitive),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("toStringTag"), .{
        .value = Value.fromSymbol(r.sym_to_string_tag),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("hasInstance"), .{
        .value = Value.fromSymbol(r.sym_has_instance),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("species"), .{
        .value = Value.fromSymbol(r.sym_species),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("match"), .{
        .value = Value.fromSymbol(r.sym_match),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("replace"), .{
        .value = Value.fromSymbol(r.sym_replace),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("search"), .{
        .value = Value.fromSymbol(r.sym_search),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("split"), .{
        .value = Value.fromSymbol(r.sym_split),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("matchAll"), .{
        .value = Value.fromSymbol(r.sym_match_all),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.defineProperty(r.symbol_namespace, try rt.heap.internAscii("isConcatSpreadable"), .{
        .value = Value.fromSymbol(r.sym_is_concat_spreadable),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_match), .{
        .value = Value.fromNative(&regexp_sym_match),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_replace), .{
        .value = Value.fromNative(&regexp_sym_replace),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_search), .{
        .value = Value.fromNative(&regexp_sym_search),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_split), .{
        .value = Value.fromNative(&regexp_sym_split),
        .enumerable = false,
    });
    try rt.heap.definePropKey(r.regexp_prototype, heap_mod.PropKey.fromSymbol(r.sym_match_all), .{
        .value = Value.fromNative(&regexp_sym_match_all),
        .enumerable = false,
    });
    try object.defineAccessor(rt, Value.fromObject(r.array_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&species_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.regexp_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&species_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.promise_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&species_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.map_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&species_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(r.set_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&species_getter), false, false);
    try defineToStringTag(rt, r.map_prototype, r.sym_to_string_tag, "Map");
    try defineToStringTag(rt, r.set_prototype, r.sym_to_string_tag, "Set");
    try defineToStringTag(rt, r.weak_map_prototype, r.sym_to_string_tag, "WeakMap");
    try defineToStringTag(rt, r.weak_set_prototype, r.sym_to_string_tag, "WeakSet");
    try defineToStringTag(rt, r.promise_prototype, r.sym_to_string_tag, "Promise");
    try defineToStringTag(rt, r.symbol_prototype, r.sym_to_string_tag, "Symbol");
    try defineToStringTag(rt, r.math, r.sym_to_string_tag, "Math");
    try defineToStringTag(rt, r.json, r.sym_to_string_tag, "JSON");
    try defineToStringTag(rt, r.generator_prototype, r.sym_to_string_tag, "Generator");
    try defineToStringTag(rt, r.async_generator_prototype, r.sym_to_string_tag, "AsyncGenerator");
    try defineToStringTag(rt, r.generator_function_prototype, r.sym_to_string_tag, "GeneratorFunction");
    try defineToStringTag(rt, r.async_generator_function_prototype, r.sym_to_string_tag, "AsyncGeneratorFunction");
    try defineToStringTag(rt, r.async_function_prototype, r.sym_to_string_tag, "AsyncFunction");
    try rt.heap.definePropKey(r.function_prototype, heap_mod.PropKey.fromSymbol(r.sym_has_instance), .{
        .value = Value.fromNative(&function_has_instance),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try method(rt, r.symbol_namespace, "for", &symbol_for);
    try method(rt, r.symbol_namespace, "keyFor", &symbol_key_for);
    try constant(rt, r.symbol_prototype, "constructor", Value.fromNative(&symbol_global));
    try method(rt, r.symbol_prototype, "toString", &symbol_to_string);
    try method(rt, r.symbol_prototype, "valueOf", &symbol_value_of);
    try object.defineAccessor(rt, Value.fromObject(r.symbol_prototype), try object.named(rt, "description"), Value.fromNative(&symbol_description_getter), false, false);
    try rt.heap.defineProperty(r.bigint_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(r.bigint_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try method(rt, r.bigint_namespace, "asIntN", &bigint_as_int_n);
    try method(rt, r.bigint_namespace, "asUintN", &bigint_as_uint_n);
    try constant(rt, r.bigint_prototype, "constructor", Value.fromNative(&bigint_global));
    try method(rt, r.bigint_prototype, "toString", &bigint_to_string);
    try method(rt, r.bigint_prototype, "valueOf", &bigint_value_of);
    try defineToStringTag(rt, r.bigint_prototype, r.sym_to_string_tag, "BigInt");
    _ = &r;
    rt.realm = r;
    return &rt.realm.?;
}

fn builtin(h: *heap_mod.Heap, proto: ?*Object, b: names.Builtin) Error!*Object {
    const o = try h.newObject(proto);
    o.builtin = b;
    return o;
}

fn method(rt: *Runtime, o: *Object, name: []const u8, n: *const Native) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = Value.fromNative(n), .enumerable = false });
}

fn symbolMethod(rt: *Runtime, o: *Object, sym: *heap_mod.Symbol, n: *const Native) Error!void {
    try rt.heap.definePropKey(o, heap_mod.PropKey.fromSymbol(sym), .{ .value = Value.fromNative(n), .enumerable = false });
}

fn defineToStringTag(rt: *Runtime, o: *Object, sym: *heap_mod.Symbol, tag: []const u8) Error!void {
    try rt.heap.definePropKey(o, heap_mod.PropKey.fromSymbol(sym), .{
        .value = Value.fromString(try rt.heap.ascii(tag)),
        .enumerable = false,
        .writable = false,
        .configurable = true,
    });
}

fn link(rt: *Runtime, o: *Object, name: []const u8, target: *Object) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = Value.fromObject(target), .enumerable = false, .writable = false });
}

fn constant(rt: *Runtime, o: *Object, name: []const u8, v: Value) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = v, .enumerable = false });
}

fn immutableConstant(rt: *Runtime, o: *Object, name: []const u8, v: Value) Error!void {
    const k = try rt.heap.internAscii(name);
    try rt.heap.defineProperty(o, k, .{ .value = v, .enumerable = false, .writable = false, .configurable = false });
}

pub const function_has_instance: Native = .{ .name = "[Symbol.hasInstance]", .length = 1, .call = functionHasInstance };

fn functionHasInstance(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return Value.fromBool(try object.ordinaryHasInstance(rt, this, arg(args, 0)));
}

const species_getter: Native = .{ .name = "get [Symbol.species]", .call = speciesGetter };

fn speciesGetter(_: *Runtime, this: Value, _: []const Value) Error!Value {
    return this;
}

fn constructValue(rt: *Runtime, ctor: Value, args: []const Value) Error!Value {
    return switch (ctor.unpack()) {
        .closure => |c| rt.constructClosure(c, args, ctor),
        .native => construct(rt, ctor, args),
        .object => |o| if (o.kind == .proxy) callProxyConstruct(rt, o, args, ctor) else rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }}),
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }}),
    };
}

fn speciesConstructor(rt: *Runtime, o_val: Value, default_ctor: Value) Error!Value {
    var root_buf = [_]Value{ o_val, default_ctor, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = try object.get(rt, o_val, try object.named(rt, "constructor"));
    if (ctor.isUndefined()) return default_ctor;
    if (!ctor.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Species constructor is not an object" }});
    }
    root_buf[2] = ctor;
    const r = try realm(rt);
    const s = try object.get(rt, ctor, .{ .symbol = r.sym_species });
    if (s.isUndefined() or s.isNull()) return default_ctor;
    if (!isConstructor(s)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Species is not a constructor" }});
    }
    return s;
}

fn arraySpeciesCreate(rt: *Runtime, original: Value, len: usize) Error!Value {
    const r = try realm(rt);
    if (!original.isObject() or original.asObject().kind != .array) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    var root_buf = [_]Value{ original, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = try object.get(rt, original, try object.named(rt, "constructor"));
    if (ctor.isUndefined()) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    if (!ctor.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Array constructor is not an object" }});
    }
    root_buf[1] = ctor;
    const s = try object.get(rt, ctor, .{ .symbol = r.sym_species });
    if (s.isUndefined() or s.isNull() or (s.isNative() and s.asNative() == &array_global)) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    if (!isConstructor(s)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Array species is not a constructor" }});
    }
    return constructValue(rt, s, &.{Value.fromNumber(@floatFromInt(len))});
}

fn arrayAppendOrDefine(rt: *Runtime, out: Value, idx: usize, val: Value) Error!void {
    if (out.isObject() and out.asObject().kind == .array and idx == out.asObject().kind.array.items.len) {
        try rt.heap.appendElement(out.asObject(), val);
        return;
    }
    if (out.isObject()) {
        try object.define(rt, out.asObject(), .{ .index = @intCast(idx) }, val);
        return;
    }
    try object.setStrict(rt, out, .{ .index = @intCast(idx) }, val);
}

const error_is_error: Native = .{ .name = "isError", .length = 1, .call = errorIsError };

fn errorIsError(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return Value.fromBool(v.isObject() and v.asObject().ordinary_tag == .@"error");
}

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
        .array_buffer => (try viewsRealm(rt)).array_buffer_namespace,
        .data_view => (try viewsRealm(rt)).data_view_namespace,
        .typed_array => (try viewsRealm(rt)).typed_array_namespace,
        .int8_array => (try viewsRealm(rt)).typed_array_namespaces[0],
        .uint8_array => (try viewsRealm(rt)).typed_array_namespaces[1],
        .uint8_clamped_array => (try viewsRealm(rt)).typed_array_namespaces[2],
        .int16_array => (try viewsRealm(rt)).typed_array_namespaces[3],
        .uint16_array => (try viewsRealm(rt)).typed_array_namespaces[4],
        .int32_array => (try viewsRealm(rt)).typed_array_namespaces[5],
        .uint32_array => (try viewsRealm(rt)).typed_array_namespaces[6],
        .float32_array => (try viewsRealm(rt)).typed_array_namespaces[7],
        .float64_array => (try viewsRealm(rt)).typed_array_namespaces[8],
        .bigint64_array => (try viewsRealm(rt)).typed_array_namespaces[9],
        .biguint64_array => (try viewsRealm(rt)).typed_array_namespaces[10],
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
        .array_buffer => (try viewsRealm(rt)).array_buffer_prototype,
        .data_view => (try viewsRealm(rt)).data_view_prototype,
        .typed_array => (try viewsRealm(rt)).typed_array_prototype,
        .int8_array => (try viewsRealm(rt)).typed_array_prototypes[0],
        .uint8_array => (try viewsRealm(rt)).typed_array_prototypes[1],
        .uint8_clamped_array => (try viewsRealm(rt)).typed_array_prototypes[2],
        .int16_array => (try viewsRealm(rt)).typed_array_prototypes[3],
        .uint16_array => (try viewsRealm(rt)).typed_array_prototypes[4],
        .int32_array => (try viewsRealm(rt)).typed_array_prototypes[5],
        .uint32_array => (try viewsRealm(rt)).typed_array_prototypes[6],
        .float32_array => (try viewsRealm(rt)).typed_array_prototypes[7],
        .float64_array => (try viewsRealm(rt)).typed_array_prototypes[8],
        .bigint64_array => (try viewsRealm(rt)).typed_array_prototypes[9],
        .biguint64_array => (try viewsRealm(rt)).typed_array_prototypes[10],
    };
}

// ---------------------------------------------------------------- globals

pub const print: Native = .{ .name = "print", .call = printImpl };
pub const object_global: Native = .{ .name = "Object", .length = 1, .call = objectCall, .construct = objectConstruct, .namespace = .object };
pub const array_global: Native = .{ .name = "Array", .length = 1, .call = arrayCall, .construct = arrayConstruct, .namespace = .array };
pub const string_global: Native = .{ .name = "String", .length = 1, .call = stringCall, .construct = stringConstruct, .namespace = .string };
pub const number_global: Native = .{ .name = "Number", .length = 1, .call = numberCall, .construct = numberConstruct, .namespace = .number };
pub const boolean_global: Native = .{ .name = "Boolean", .length = 1, .call = booleanCall, .construct = booleanConstruct, .namespace = .boolean };
pub const function_global: Native = .{ .name = "Function", .length = 1, .call = notCallable, .namespace = .function };
pub const parse_int_global: Native = .{ .name = "parseInt", .length = 2, .call = parseIntImpl };
pub const parse_float_global: Native = .{ .name = "parseFloat", .length = 1, .call = parseFloatImpl };
pub const is_nan_global: Native = .{ .name = "isNaN", .length = 1, .call = globalIsNaN };
pub const is_finite_global: Native = .{ .name = "isFinite", .length = 1, .call = globalIsFinite };
pub const encode_uri_global: Native = .{ .name = "encodeURI", .length = 1, .call = globalEncodeURI };
pub const decode_uri_global: Native = .{ .name = "decodeURI", .length = 1, .call = globalDecodeURI };
pub const encode_uri_component_global: Native = .{ .name = "encodeURIComponent", .length = 1, .call = globalEncodeURIComponent };
pub const decode_uri_component_global: Native = .{ .name = "decodeURIComponent", .length = 1, .call = globalDecodeURIComponent };
pub const map_global: Native = .{ .name = "Map", .call = mapWithoutNew, .construct = mapConstruct, .namespace = .map };
pub const set_global: Native = .{ .name = "Set", .call = setWithoutNew, .construct = setConstruct, .namespace = .set };
pub const weak_map_global: Native = .{ .name = "WeakMap", .call = weakMapWithoutNew, .construct = weakMapConstruct, .namespace = .weak_map };
pub const weak_set_global: Native = .{ .name = "WeakSet", .call = weakSetWithoutNew, .construct = weakSetConstruct, .namespace = .weak_set };
pub const iterator_global: Native = .{ .name = "Iterator", .call = iteratorWithoutNew, .construct = iteratorConstruct, .namespace = .iterator };
pub const promise_global: Native = .{ .name = "Promise", .length = 1, .call = promiseWithoutNew, .construct = promiseConstruct, .namespace = .promise };
pub const error_global: Native = .{ .name = "Error", .length = 1, .call = errorCall, .construct = errorConstruct, .namespace = .@"error" };
pub const type_error_global: Native = .{ .name = "TypeError", .length = 1, .call = typeErrorCall, .construct = typeErrorConstruct, .namespace = .type_error };
pub const range_error_global: Native = .{ .name = "RangeError", .length = 1, .call = rangeErrorCall, .construct = rangeErrorConstruct, .namespace = .range_error };
pub const syntax_error_global: Native = .{ .name = "SyntaxError", .length = 1, .call = syntaxErrorCall, .construct = syntaxErrorConstruct, .namespace = .syntax_error };
pub const reference_error_global: Native = .{ .name = "ReferenceError", .length = 1, .call = referenceErrorCall, .construct = referenceErrorConstruct, .namespace = .reference_error };
pub const eval_error_global: Native = .{ .name = "EvalError", .length = 1, .call = evalErrorCall, .construct = evalErrorConstruct, .namespace = .eval_error };
pub const uri_error_global: Native = .{ .name = "URIError", .length = 1, .call = uriErrorCall, .construct = uriErrorConstruct, .namespace = .uri_error };
pub const aggregate_error_global: Native = .{ .name = "AggregateError", .length = 2, .call = aggregateErrorCall, .construct = aggregateErrorConstruct, .namespace = .aggregate_error };
pub const regexp_global: Native = .{ .name = "RegExp", .length = 2, .call = regexpCall, .construct = regexpConstruct, .namespace = .regexp };
pub const date_global: Native = .{ .name = "Date", .length = 7, .call = dateCall, .construct = dateConstruct, .namespace = .date };
pub const symbol_global: Native = .{ .name = "Symbol", .call = symbolCall, .namespace = .symbol };
pub const bigint_global: Native = .{ .name = "BigInt", .length = 1, .call = bigintCall, .namespace = .bigint };
pub const structured_clone_global: Native = .{ .name = "structuredClone", .length = 1, .call = structuredCloneCall };

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
    .{ "structuredClone", .{ .native = &structured_clone_global } },
});

fn resolveGlobalTarget(rt: *Runtime, target: GlobalTarget) Error!Value {
    return switch (target) {
        .undefined => .undefined,
        .nan => Value.fromNumber(std.math.nan(f64)),
        .inf => Value.fromNumber(std.math.inf(f64)),
        .math => Value.fromObject((try realm(rt)).math),
        .json => Value.fromObject((try realm(rt)).json),
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
    }
    if (builtin_globals.get(name)) |target| {
        return try resolveGlobalTarget(rt, target);
    }
    for (rt.host_globals.items) |n| if (std.mem.eql(u8, n.name, name)) return Value.fromNative(n);
    if (names.has(.global, name)) {
        rt.unsupported_name = try rt.heap.internAscii(name);
        return rt.fail(.builtin);
    }
    return null;
}

pub fn setGlobal(rt: *Runtime, name: []const u8, val: Value, strict: bool) Error!void {
    const r = try realm(rt);
    var root_buf = [_]Value{val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const k = try object.named(rt, name);
    var exists = r.global_object.props.get(try object.propKey(rt, k)) != null or builtin_globals.get(name) != null;
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
    return try toObjectReceiver(rt, v);
}

pub fn globalOwnProp(rt: *Runtime, atom: *const heap_mod.String) Error!?heap_mod.Property {
    if (atom.units.len > 64) return null;
    var buf: [64]u8 = undefined;
    for (atom.units, 0..) |u, i| {
        if (u > 0x7f) return null;
        buf[i] = @intCast(u);
    }
    const name = buf[0..atom.units.len];
    if (builtin_globals.get(name)) |target| {
        const is_const = target == .undefined or target == .nan or target == .inf;
        return .{
            .value = try resolveGlobalTarget(rt, target),
            .enumerable = false,
            .writable = !is_const,
            .configurable = !is_const,
        };
    }
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
    return std.mem.eql(u8, name, "print") or std.mem.eql(u8, name, "structuredClone") or names.has(.global, name);
}

fn notCallable(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    _ = args;
    return rt.fail(.builtin); // Object(…) / Array(…): the constructors themselves
}

/// Evaluates `new callee(args...)` for built-in constructors (M14).
pub fn construct(rt: *Runtime, callee: Value, args: []const Value) Error!Value {
    return switch (callee.unpack()) {
        .native => |n| if (n.construct) |c| c(rt, args) else if (n == &symbol_global or n == &bigint_global) rt.throw(.TypeError, &.{ .{ .ascii = n.name }, .{ .ascii = " is not a constructor" } }) else if (n.namespace != null) rt.fail(.builtin) else rt.throw(.TypeError, &.{ .{ .ascii = n.name }, .{ .ascii = " is not a constructor" } }),
        .closure => rt.fail(.builtin),
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }}),
    };
}

// ---------------------------------------------------------------- Functions (M31, D62)

/// Whether closure `c` has an own, lazily created `.prototype`: constructable functions
/// and generator functions (including generator methods, D67).
pub fn hasAutoPrototype(c: *const heap_mod.Closure) bool {
    return switch (c.impl) {
        .vm => |v| blk: {
            const p: *const bytecode.Proto = @ptrCast(@alignCast(v.proto));
            break :blk p.is_generator or (!p.is_arrow and !p.is_async and !p.is_method);
        },
        .tree => |t| blk: {
            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
            break :blk f.is_generator or (!f.is_arrow and !f.is_async and !f.is_method);
        },
        .promise_cap, .native_closure, .bound => false,
    };
}

pub fn isGeneratorFunction(c: *const heap_mod.Closure) bool {
    return switch (c.impl) {
        .vm => |v| @as(*const bytecode.Proto, @ptrCast(@alignCast(v.proto))).is_generator,
        .tree => |t| @as(*const ast.Function, @ptrCast(@alignCast(t.func))).is_generator,
        .promise_cap, .native_closure, .bound => false,
    };
}

pub const FunctionKind = enum { normal, generator, async_function, async_generator };

pub fn functionKind(c: *const heap_mod.Closure) FunctionKind {
    const is_async: bool, const is_gen: bool = switch (c.impl) {
        .vm => |v| blk: {
            const p: *const bytecode.Proto = @ptrCast(@alignCast(v.proto));
            break :blk .{ p.is_async_generator or (p.is_async and !p.is_generator), p.is_generator };
        },
        .tree => |t| blk: {
            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
            break :blk .{ f.is_async, f.is_generator };
        },
        .promise_cap, .native_closure, .bound => .{ false, false },
    };
    if (is_gen) return if (is_async) .async_generator else .generator;
    return if (is_async) .async_function else .normal;
}

/// A closure's `[[Prototype]]` when `ClosureMeta.proto` doesn't set one (D68):
/// %GeneratorFunction.prototype%, %AsyncGeneratorFunction.prototype%,
/// %AsyncFunction.prototype% or %Function.prototype% by its kind.
pub fn closureDefaultProto(rt: *Runtime, c: *const heap_mod.Closure) Error!*Object {
    const r = try realm(rt);
    return switch (functionKind(c)) {
        .normal => r.function_prototype,
        .generator => r.generator_function_prototype,
        .async_function => r.async_function_prototype,
        .async_generator => r.async_generator_function_prototype,
    };
}

pub fn isConstructor(v: Value) bool {
    return switch (v.unpack()) {
        .native => |n| n.construct != null or (n.namespace != null and n.namespace.? != .symbol),
        .closure => |c| switch (c.impl) {
            .vm, .tree => hasAutoPrototype(c) and !isGeneratorFunction(c),
            .bound => |b| isConstructor(b.target),
            .promise_cap, .native_closure => false,
        },
        .object => |o| o.kind == .proxy and o.kind.proxy.is_constructable,
        else => false,
    };
}

pub fn closureName(rt: *Runtime, c: *const heap_mod.Closure) Error!*const heap_mod.String {
    const raw: []const u8 = switch (c.impl) {
        .vm => |v| blk: {
            const p: *const bytecode.Proto = @ptrCast(@alignCast(v.proto));
            break :blk if (p.name.len > 0) p.name else p.inferred_name;
        },
        .tree => |t| blk: {
            const f: *const ast.Function = @ptrCast(@alignCast(t.func));
            break :blk if (f.name) |n| n.name else f.inferred_name;
        },
        .bound => |b| return b.name,
        .promise_cap, .native_closure => "",
    };
    return rt.heap.ascii(raw);
}

pub fn closureLength(c: *const heap_mod.Closure) u16 {
    return switch (c.impl) {
        .vm => |v| @as(*const bytecode.Proto, @ptrCast(@alignCast(v.proto))).length,
        .tree => |t| @as(*const ast.Function, @ptrCast(@alignCast(t.func))).length,
        .bound => |b| b.length,
        .promise_cap, .native_closure => 0,
    };
}

pub fn isClassConstructor(v: Value) bool {
    if (v != .closure) return false;
    return switch (v.closure.impl) {
        .vm => |vm_impl| @as(*const bytecode.Proto, @ptrCast(@alignCast(vm_impl.proto))).is_class_constructor,
        .tree => |tr| @as(*const ast.Function, @ptrCast(@alignCast(tr.func))).is_class_constructor,
        .bound, .promise_cap, .native_closure => false,
    };
}

pub fn setupClass(rt: *Runtime, ctor_val: Value, has_super: bool, super_val: Value) Error!*Object {
    var root_buf = [_]Value{ ctor_val, super_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ctor = @constCast(ctor_val.asClosure());
    const r = try realm(rt);
    const super_proto: ?*Object = if (!has_super)
        r.object_prototype
    else if (super_val.isNull())
        null
    else blk: {
        if (!isConstructor(super_val)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Class extends value is not a constructor or null" }});
        }
        const sp = try object.get(rt, super_val, try object.named(rt, "prototype"));
        if (sp.isNull()) break :blk null;
        if (!sp.isObject()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Class extends value has non-object prototype" }});
        }
        try rt.heap.storeClosureProto(ctor, super_val);
        break :blk sp.asObject();
    };

    const proto_obj = try rt.heap.newObject(super_proto);
    root_buf[2] = Value.fromObject(proto_obj);
    const ctor_key = try rt.heap.internAscii("constructor");
    try rt.heap.defineProperty(proto_obj, ctor_key, .{ .value = ctor_val, .enumerable = false });
    try rt.heap.storeClosurePrototype(ctor, Value.fromObject(proto_obj));
    try rt.heap.storeClosureHomeObject(ctor, Value.fromObject(proto_obj));
    try rt.heap.storeClosureBrand(ctor, ctor_val);
    return proto_obj;
}

pub fn runInstanceInits(rt: *Runtime, ctor: *heap_mod.Closure, this_val: Value) Error!void {
    const m = ctor.meta orelse return;
    if (m.instance_inits.len == 0) return;
    var root_buf = [_]Value{ Value.fromClosure(ctor), this_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..m.instance_inits.len) |i| {
        const entry = ctor.meta.?.instance_inits[i];
        switch (entry.kind) {
            .private_method => try object.definePrivateMethod(rt, this_val, ctor, entry.name.?, entry.func),
            .private_getter => try object.definePrivateAccessor(rt, this_val, ctor, entry.name.?, entry.func, false),
            .private_setter => try object.definePrivateAccessor(rt, this_val, ctor, entry.name.?, entry.func, true),
            .public_field => {
                const key_val = ctor.meta.?.field_keys[entry.key_idx];
                const val: Value = if (entry.func.isUndefined()) .undefined else try rt.callCallable(entry.func, this_val, &.{});
                root_buf[2] = val;
                const k = try object.key(rt, key_val);
                try object.definePublicField(rt, this_val, k, val);
                root_buf[2] = .undefined;
            },
            .private_field => {
                const val: Value = if (entry.func.isUndefined()) .undefined else try rt.callCallable(entry.func, this_val, &.{});
                root_buf[2] = val;
                try object.definePrivateField(rt, this_val, ctor, entry.name.?, val);
                root_buf[2] = .undefined;
            },
        }
    }
}

pub fn defineClassMethod(rt: *Runtime, target: Value, k: object.Key, method_val: Value) Error!void {
    try rt.heap.storeClosureHomeObject(@constCast(method_val.asClosure()), target);
    try object.defineNonEnumerable(rt, target, k, method_val);
}

pub fn defineClassAccessor(rt: *Runtime, target: Value, k: object.Key, fn_val: Value, is_setter: bool) Error!void {
    try rt.heap.storeClosureHomeObject(@constCast(fn_val.asClosure()), target);
    try object.defineAccessor(rt, target, k, fn_val, is_setter, false);
}

pub fn materializeClosurePrototype(rt: *Runtime, c: *heap_mod.Closure) Error!*Object {
    const r = try realm(rt);
    if (isGeneratorFunction(c)) { // inherits %(Async)GeneratorPrototype%, no `constructor` (D67, D68)
        const gen_proto = try rt.heap.newObject(if (functionKind(c) == .async_generator) r.async_generator_prototype else r.generator_prototype);
        try rt.heap.storeClosurePrototype(c, Value.fromObject(gen_proto));
        return gen_proto;
    }
    const proto_obj = try rt.heap.newObject(r.object_prototype);
    const ctor_key = try rt.heap.internAscii("constructor");
    try rt.heap.defineProperty(proto_obj, ctor_key, .{ .value = Value.fromClosure(c), .enumerable = false });
    try rt.heap.storeClosurePrototype(c, Value.fromObject(proto_obj));
    return proto_obj;
}

const function_call: Native = .{ .name = "call", .length = 1, .call = functionCall };
const function_apply: Native = .{ .name = "apply", .length = 2, .call = functionApply };
const function_bind: Native = .{ .name = "bind", .length = 1, .call = functionBind };

fn functionCall(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Function.prototype.call called on non-function" }});
    const this_arg = arg(args, 0);
    const call_args = if (args.len > 1) args[1..] else &[_]Value{};
    return rt.callCallable(this, this_arg, call_args);
}

fn functionApply(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Function.prototype.apply called on non-function" }});
    const this_arg = arg(args, 0);
    const arg_array = arg(args, 1);
    if (arg_array.isUndefined() or arg_array.isNull()) {
        return rt.callCallable(this, this_arg, &.{});
    }
    if (!arg_array.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "CreateListFromArrayLike called on non-object" }});
    }
    if (arg_array.isObject() and arg_array.asObject().kind == .array) {
        const items = arg_array.asObject().kind.array.items;
        const copy = try rt.gpa.dupe(Value, items);
        defer rt.gpa.free(copy);
        var root_buf = [_]Value{ this, this_arg };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        // Keep copied args rooted? They are in `copy` on Zig heap, wait: if GC runs inside callCallable,
        // `rt.callCallable` copies them to VM stack or Machine values immediately before any safepoint.
        return rt.callCallable(this, this_arg, copy);
    }
    const len_val = try object.get(rt, arg_array, try object.named(rt, "length"));
    const len_n = try toIntegerOrInfinity(rt, len_val);
    const len: usize = if (len_n <= 0) 0 else @intFromFloat(@min(len_n, @as(f64, @floatFromInt(rt.limits.max_stack_slots))));
    const list = try rt.gpa.alloc(Value, len);
    defer rt.gpa.free(list);
    for (0..len) |i| {
        list[i] = try object.get(rt, arg_array, .{ .index = @intCast(i) });
    }
    return rt.callCallable(this, this_arg, list);
}

fn functionBind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Bind must be called on a function" }});
    const this_arg = arg(args, 0);
    const new_bound_args = if (args.len > 1) args[1..] else &[_]Value{};

    var target: Value = this;
    var effective_this: Value = this_arg;
    var prev_args: []const Value = &.{};
    var target_len: u16 = 0;
    var target_name: []const u8 = "";
    var target_name_str: ?*const heap_mod.String = null;

    if (this.isClosure() and this.asClosure().impl == .bound) {
        const prev = this.asClosure().impl.bound;
        target = prev.target;
        effective_this = prev.bound_this;
        prev_args = prev.bound_args;
        target_len = prev.length;
        target_name_str = prev.name;
    } else switch (this.unpack()) {
        .native => |n| {
            target_len = n.length;
            target_name = n.name;
        },
        .closure => |c| {
            target_len = closureLength(c);
            target_name_str = try closureName(rt, c);
        },
        .object => {
            if (try object.hasOwn(rt, this, try object.named(rt, "length"))) {
                const lv = try object.get(rt, this, try object.named(rt, "length"));
                if (lv.isNumber()) {
                    const n = @trunc(lv.asNumber());
                    if (n > 0 and !std.math.isNan(n)) {
                        target_len = @intFromFloat(@min(n, 65535.0));
                    }
                }
            }
            const nv = try object.get(rt, this, try object.named(rt, "name"));
            if (nv.isString()) target_name_str = nv.asString();
        },
        else => unreachable,
    }

    const combined = try rt.gpa.alloc(Value, prev_args.len + new_bound_args.len);
    defer rt.gpa.free(combined);
    @memcpy(combined[0..prev_args.len], prev_args);
    @memcpy(combined[prev_args.len..], new_bound_args);

    const bound_len: u16 = target_len -| @as(u16, @intCast(@min(target_len, new_bound_args.len)));
    const name_str = if (target_name_str) |s|
        try rt.heap.newString(&.{ .{ .ascii = "bound " }, .{ .utf16 = s.units } })
    else
        try rt.heap.newString(&.{ .{ .ascii = "bound " }, .{ .ascii = target_name } });

    const bound_c = try rt.heap.newBoundClosure(target, effective_this, combined, name_str, bound_len);
    return Value.fromClosure(bound_c);
}

/// `print(a, b, …)` writes `String(a) + " " + String(b) + … + "\n"`. The node test
/// harness defines the same function, so outputs compare byte for byte.
fn printImpl(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = this;
    for (args, 0..) |value, i| {
        if (i > 0) try rt.out.writeByte(' ');
        if (value.isSymbol()) {
            try rt.out.writeAll("Symbol(");
            if (value.asSymbol().description) |d| try ops.writeUtf16(rt.out, d.units);
            try rt.out.writeByte(')');
            continue;
        }
        var buf: ops.NumberBuf = undefined;
        switch (try ops.toPiece(rt, value, &buf)) {
            .ascii => |s| try rt.out.writeAll(s),
            .utf16 => |units| try ops.writeUtf16(rt.out, units),
        }
    }
    try rt.out.writeByte('\n');
    return .undefined;
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

/// A member called on a receiver it doesn't implement (e.g. push on a non-array):
/// node would do something generic that ZQJS doesn't.
fn unsupportedReceiver(rt: *Runtime, name: []const u8) Error {
    rt.unsupported_name = try rt.heap.internAscii(name);
    return rt.fail(.builtin);
}

// ---------------------------------------------------------------- Object.prototype

/// Allocates an ES unmapped `arguments` object (CreateUnmappedArgumentsObject).
pub fn newArgumentsObject(rt: *Runtime, args: []const Value) Error!*heap_mod.Object {
    const r = try realm(rt);
    const obj = try rt.heap.newObject(r.object_prototype);
    obj.ordinary_tag = .arguments;
    var root_buf = [_]Value{Value.fromObject(obj)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var idx_buf: [20]u8 = undefined;
    for (args, 0..) |v, i| {
        const s = std.fmt.bufPrint(&idx_buf, "{d}", .{i}) catch unreachable;
        const k = try rt.heap.internUtf8(s);
        try rt.heap.defineProperty(obj, k, .{
            .value = v,
            .writable = true,
            .enumerable = true,
            .configurable = true,
        });
    }
    const len_key = try rt.heap.internUtf8("length");
    try rt.heap.defineProperty(obj, len_key, .{
        .value = Value.fromNumber(@floatFromInt(args.len)),
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    try symbolMethod(rt, obj, r.sym_iterator, &array_values);
    return obj;
}

const object_to_string: Native = .{ .name = "toString", .call = objectToString };
const object_value_of: Native = .{ .name = "valueOf", .call = objectValueOf };

fn objectToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined()) return Value.fromString(try rt.heap.ascii("[object Undefined]"));
    if (this.isNull()) return Value.fromString(try rt.heap.ascii("[object Null]"));
    const builtin_tag: []const u8 = switch (this.unpack()) {
        .undefined, .null => unreachable,
        .boolean => "Boolean",
        .number => "Number",
        .string => "String",
        .symbol => "Object",
        .bigint => "Object",
        .native, .closure => "Function",
        .object => |o| switch (o.kind) {
            .array => "Array",
            .iterator => |it| switch (it.kind) {
                .map_entries, .map_keys, .map_values => "Map Iterator",
                .set_values, .set_entries => "Set Iterator",
                .array_values, .array_keys, .array_entries => "Array Iterator",
                .string_chars => "String Iterator",
                .regexp_match_all => "RegExp String Iterator",
                .helper => "Iterator Helper",
                .wrap => "Iterator",
                .custom, .async_from_sync, .for_in => "Object",
            },
            .regexp => "RegExp",
            .date => "Date",
            .module_namespace => "Module",
            .ordinary => switch (o.ordinary_tag) {
                .arguments => "Arguments",
                .@"error" => "Error",
                .plain => if (o.builtin == .number_prototype) "Number" else if (o.builtin == .boolean_prototype) "Boolean" else if (o.builtin == .string_prototype) "String" else "Object",
            },
            .primitive_wrapper => |pv| switch (pv.unpack()) {
                .boolean => "Boolean",
                .number => "Number",
                .string => "String",
                else => "Object",
            },
            else => "Object",
        },
    };
    const r = try realm(rt);
    var roots_buf = [_]Value{this};
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const tag_val = try object.get(rt, this, .{ .symbol = r.sym_to_string_tag });
    if (tag_val.isString()) {
        roots_buf[0] = tag_val;
        return Value.fromString(try rt.heap.newString(&.{ .{ .ascii = "[object " }, .{ .utf16 = tag_val.asString().units }, .{ .ascii = "]" } }));
    }
    return Value.fromString(try rt.heap.newString(&.{ .{ .ascii = "[object " }, .{ .ascii = builtin_tag }, .{ .ascii = "]" } }));
}

fn objectValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    return objectConstruct(rt, &.{this});
}

// ---------------------------------------------------------------- Array.prototype

const array_push: Native = .{ .name = "push", .call = arrayPush };
const array_pop: Native = .{ .name = "pop", .call = arrayPop };
const array_slice: Native = .{ .name = "slice", .call = arraySlice };
const array_index_of: Native = .{ .name = "indexOf", .call = arrayIndexOf };
const array_includes: Native = .{ .name = "includes", .call = arrayIncludes };
const array_join: Native = .{ .name = "join", .call = arrayJoin };
const array_to_string: Native = .{ .name = "toString", .call = arrayToString };
const array_keys: Native = .{ .name = "keys", .call = arrayKeys };
const array_values: Native = .{ .name = "values", .call = arrayValues };
const array_entries: Native = .{ .name = "entries", .call = arrayEntries };
const array_for_each: Native = .{ .name = "forEach", .call = arrayForEach };
const array_map: Native = .{ .name = "map", .call = arrayMap };
const array_filter: Native = .{ .name = "filter", .call = arrayFilter };
const array_reduce: Native = .{ .name = "reduce", .call = arrayReduce };
const array_find: Native = .{ .name = "find", .call = arrayFind };
const array_find_index: Native = .{ .name = "findIndex", .call = arrayFindIndex };
const array_find_last: Native = .{ .name = "findLast", .call = arrayFindLast };
const array_find_last_index: Native = .{ .name = "findLastIndex", .call = arrayFindLastIndex };
const array_some: Native = .{ .name = "some", .call = arraySome };
const array_every: Native = .{ .name = "every", .call = arrayEvery };
const array_concat: Native = .{ .name = "concat", .call = arrayConcat };
const array_reverse: Native = .{ .name = "reverse", .call = arrayReverse };
const array_at: Native = .{ .name = "at", .call = arrayAt };
const array_last_index_of: Native = .{ .name = "lastIndexOf", .call = arrayLastIndexOf };
const array_fill: Native = .{ .name = "fill", .call = arrayFill };
const array_shift: Native = .{ .name = "shift", .call = arrayShift };
const array_unshift: Native = .{ .name = "unshift", .call = arrayUnshift };
const array_splice: Native = .{ .name = "splice", .call = arraySplice };
const array_sort: Native = .{ .name = "sort", .call = arraySort };
const array_reduce_right: Native = .{ .name = "reduceRight", .call = arrayReduceRight };
const array_flat: Native = .{ .name = "flat", .call = arrayFlat };
const array_flat_map: Native = .{ .name = "flatMap", .call = arrayFlatMap };
const array_copy_within: Native = .{ .name = "copyWithin", .call = arrayCopyWithin };
const array_to_reversed: Native = .{ .name = "toReversed", .call = arrayToReversed };
const array_to_sorted: Native = .{ .name = "toSorted", .call = arrayToSorted };
const array_to_spliced: Native = .{ .name = "toSpliced", .call = arrayToSpliced };
const array_with: Native = .{ .name = "with", .call = arrayWith };

fn requireCallable(rt: *Runtime, v: Value) Error!Value {
    return switch (v.unpack()) {
        .native, .closure => v,
        else => rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }}),
    };
}

fn toIntegerOrInfinity(rt: *Runtime, v: Value) Error!f64 {
    const n = try ops.toNumber(rt, v);
    if (std.math.isNan(n) or n == 0) return 0;
    return @trunc(n);
}

fn resolveRelativeIndex(n: f64, len: usize) usize {
    const len_f: f64 = @floatFromInt(len);
    const k = if (n < 0) @max(len_f + n, 0) else @min(n, len_f);
    return @intFromFloat(k);
}

fn resolveSearchStart(n: f64, len: usize) ?usize {
    const len_f: f64 = @floatFromInt(len);
    if (n >= len_f) return null;
    if (n >= 0) return @intFromFloat(n);
    const k = len_f + n;
    return if (k < 0) 0 else @intFromFloat(k);
}

fn sameValueZero(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber() and std.math.isNan(a.asNumber()) and std.math.isNan(b.asNumber())) return true;
    return ops.strictEquals(a, b);
}

fn thisArray(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .array) return this.asObject();
    return unsupportedReceiver(rt, name);
}

fn checkArrayMutate(rt: *Runtime, a: *Object, opts: struct {
    grow: bool = false,
    shrink: bool = false,
    write_elements: bool = false,
    write_length: bool = false,
}) Error!void {
    if (opts.write_length and !a.array_length_writable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property 'length'" }});
    }
    if (opts.grow and (!a.extensible or !a.array_length_writable)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property, object is not extensible" }});
    }
    if (opts.shrink and (!a.array_elements_configurable or !a.array_length_writable)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property of non-configurable array" }});
    }
    if (opts.write_elements and !a.array_elements_writable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
    }
}

fn arrayPush(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "push");
    try checkArrayMutate(rt, a, .{ .grow = args.len > 0, .write_length = true });
    if (args.len == 1) {
        try rt.heap.appendElement(a, args[0]);
    } else if (args.len > 1) {
        try rt.heap.appendElements(a, args);
    }
    return Value.fromNumber(@floatFromInt(a.kind.array.items.len));
}

fn arrayPop(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const a = try thisArray(rt, this, "pop");
    try checkArrayMutate(rt, a, .{ .shrink = a.kind.array.items.len > 0, .write_length = true });
    return rt.heap.popElement(a) orelse .undefined;
}

fn toObjectReceiver(rt: *Runtime, this: Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    return if (this.isObjectLike()) this else objectConstruct(rt, &.{this});
}

/// ZQJS arrays are always dense (D13), so `slice()` always returns a dense array;
/// sparse-array hole preservation is not supported because holes are rejected at creation.
fn arraySlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        var root_buf = [_]Value{ this, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const a = this.asObject();
        const len = a.kind.array.items.len;
        const start = if (arg(args, 0).isUndefined()) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 0)), len);
        const end = if (arg(args, 1).isUndefined()) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
        const count = if (end > start) end - start else 0;
        const out_val = try arraySpeciesCreate(rt, this, count);
        root_buf[1] = out_val;
        if (out_val.isObject() and out_val.asObject().kind == .array and out_val.asObject().kind.array.items.len == 0) {
            const cur_items = a.kind.array.items;
            const actual_end = @min(end, cur_items.len);
            if (start < actual_end) try rt.heap.appendElements(out_val.asObject(), cur_items[start..actual_end]);
            return out_val;
        }
        var n: usize = 0;
        var k: usize = start;
        while (k < end) : ({
            k += 1;
            n += 1;
        }) {
            if (k < a.kind.array.items.len) {
                try arrayAppendOrDefine(rt, out_val, n, a.kind.array.items[k]);
            }
        }
        try object.setStrict(rt, out_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(n)));
        return out_val;
    }
    const o_val = try toObjectReceiver(rt, this);
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ o_val, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const start = if (arg(args, 0).isUndefined()) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 0)), len);
    const end = if (arg(args, 1).isUndefined()) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
    var k: usize = start;
    while (k < end) : (k += 1) {
        if (!try object.has(rt, .{ .index = @intCast(k) }, o_val)) return rt.fail(.sparse_array);
        root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(k) });
        try rt.heap.appendElement(out, root_buf[2]);
        root_buf[2] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        const items = this.asObject().kind.array.items;
        if (items.len == 0) return Value.fromNumber(-1);
        const needle = arg(args, 0);
        const from_n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else 0;
        const start = resolveSearchStart(from_n, items.len) orelse return Value.fromNumber(-1);
        for (items[start..], start..) |item, i| {
            if (ops.strictEquals(item, needle)) return Value.fromNumber(@floatFromInt(i));
        }
        return Value.fromNumber(-1);
    }
    const o_val = try toObjectReceiver(rt, this);
    const needle = arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    if (len == 0) return Value.fromNumber(-1);
    const from_n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else 0;
    const start = resolveSearchStart(from_n, len) orelse return Value.fromNumber(-1);
    for (start..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            if (ops.strictEquals(elem, needle)) return Value.fromNumber(@floatFromInt(i));
        }
    }
    return Value.fromNumber(-1);
}

fn arrayIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        const items = this.asObject().kind.array.items;
        if (items.len == 0) return Value.fromBool(false);
        const needle = arg(args, 0);
        const from_n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else 0;
        const start = resolveSearchStart(from_n, items.len) orelse return Value.fromBool(false);
        for (items[start..]) |item| {
            if (sameValueZero(item, needle)) return Value.fromBool(true);
        }
        return Value.fromBool(false);
    }
    const o_val = try toObjectReceiver(rt, this);
    const needle = arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    if (len == 0) return Value.fromBool(false);
    const from_n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else 0;
    const start = resolveSearchStart(from_n, len) orelse return Value.fromBool(false);
    for (start..len) |i| {
        const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
        if (sameValueZero(elem, needle)) return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

fn arrayJoin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const sep = arg(args, 0);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        if (sep.isUndefined()) return Value.fromString(try object.join(rt, a, &.{','}));
        var roots_buf = [_]Value{ o_val, .undefined };
        var roots = rt_mod.ValueRoots{ .values = &roots_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        var buf: ops.NumberBuf = undefined;
        const piece = try ops.toPiece(rt, sep, &buf);
        const sep_str = try rt.heap.newString(&.{piece});
        roots_buf[1] = Value.fromString(sep_str);
        return Value.fromString(try object.join(rt, a, sep_str.units));
    }
    var roots_buf = [_]Value{ o_val, sep, .undefined, .undefined };
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const sep_units: []const u16 = if (sep.isUndefined())
        &.{','}
    else blk: {
        const s_obj = try toStringObj(rt, sep);
        roots_buf[2] = Value.fromString(s_obj);
        break :blk s_obj.units;
    };
    if (len_f == 0) return Value.fromString(try rt.heap.newString(&.{}));
    const len: usize = @intFromFloat(len_f);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    for (0..len) |i| {
        if (i > 0) try appendUnits(rt, &out, sep_units);
        const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
        if (elem.isUndefined() or elem.isNull()) continue;
        const elem_s = try toStringObj(rt, elem);
        roots_buf[3] = Value.fromString(elem_s);
        try appendUnits(rt, &out, elem_s.units);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

/// Array.prototype.toString calls `this.join`, falling back to Object.prototype.toString.
fn arrayToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    var roots_buf = [_]Value{this};
    var roots = rt_mod.ValueRoots{ .values = &roots_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const j = try object.get(rt, this, try object.named(rt, "join"));
    if (j.isNative() and j.asNative() == &array_join) return arrayJoin(rt, this, &.{});
    if (j.isFunction()) return rt.callCallable(j, this, &.{});
    return objectToString(rt, this, &.{}); // join not callable: the Object.prototype one
}

fn arrayKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_keys));
}

fn arrayValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_values));
}

fn arrayEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_entries));
}

fn arrayForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ o_val, arg(args, 0), this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try requireCallable(rt, root_buf[1]);
        for (0..len) |i| {
            if (i >= a.kind.array.items.len) continue;
            const elem = a.kind.array.items[i];
            _ = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
        }
        return .undefined;
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try requireCallable(rt, root_buf[1]);
    for (0..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            _ = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
        }
    }
    return .undefined;
}

fn arrayMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const this_arg = arg(args, 1);
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ o_val, arg(args, 0), this_arg, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try requireCallable(rt, root_buf[1]);
        for (0..len) |i| {
            if (i >= a.kind.array.items.len) return rt.fail(.sparse_array);
            const elem = a.kind.array.items[i];
            root_buf[4] = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            try rt.heap.appendElement(out, root_buf[4]);
            root_buf[4] = .undefined;
        }
        return Value.fromObject(out);
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try requireCallable(rt, root_buf[1]);
    for (0..len) |i| {
        if (!try object.has(rt, .{ .index = @intCast(i) }, o_val)) return rt.fail(.sparse_array);
        const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
        root_buf[4] = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
        try rt.heap.appendElement(out, root_buf[4]);
        root_buf[4] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayFilter(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const this_arg = arg(args, 1);
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ o_val, arg(args, 0), this_arg, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try requireCallable(rt, root_buf[1]);
        for (0..len) |i| {
            if (i >= a.kind.array.items.len) continue;
            const elem = a.kind.array.items[i];
            root_buf[4] = elem;
            const keep = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(keep)) try rt.heap.appendElement(out, root_buf[4]);
            root_buf[4] = .undefined;
        }
        return Value.fromObject(out);
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try requireCallable(rt, root_buf[1]);
    for (0..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            root_buf[4] = elem;
            const keep = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(keep)) try rt.heap.appendElement(out, root_buf[4]);
            root_buf[4] = .undefined;
        }
    }
    return Value.fromObject(out);
}

fn arrayReduce(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, arg(args, 0), arg(args, 1) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const cb = try requireCallable(rt, root_buf[1]);
        const elems = a.kind.array.items;
        const len = elems.len;
        var start: usize = 0;
        if (args.len < 2) {
            if (len == 0) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
            root_buf[2] = elems[0];
            start = 1;
        }
        for (start..len) |i| {
            if (i >= a.kind.array.items.len) continue;
            const elem = a.kind.array.items[i];
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(i)), o_val });
        }
        return root_buf[2];
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try requireCallable(rt, root_buf[1]);
    var k: usize = 0;
    if (args.len < 2) {
        var found = false;
        while (k < len) : (k += 1) {
            if (try object.has(rt, .{ .index = @intCast(k) }, o_val)) {
                root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(k) });
                k += 1;
                found = true;
                break;
            }
        }
        if (!found) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
    }
    while (k < len) : (k += 1) {
        if (try object.has(rt, .{ .index = @intCast(k) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(k) });
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(k)), o_val });
        }
    }
    return root_buf[2];
}

const FindMode = enum { find, find_index, find_last, find_last_index };

fn arrayFindImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime mode: FindMode) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ o_val, arg(args, 0), this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const reverse = (mode == .find_last or mode == .find_last_index);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try requireCallable(rt, root_buf[1]);
        for (0..len) |step| {
            const i = if (reverse) len - 1 - step else step;
            const elem = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.undefined;
            root_buf[3] = elem;
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(res)) {
                return switch (mode) {
                    .find, .find_last => root_buf[3],
                    .find_index, .find_last_index => Value.fromNumber(@floatFromInt(i)),
                };
            }
            root_buf[3] = .undefined;
        }
    } else {
        const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
        const cb = try requireCallable(rt, root_buf[1]);
        const len: usize = @intFromFloat(len_f);
        for (0..len) |step| {
            const i = if (reverse) len - 1 - step else step;
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            root_buf[3] = elem;
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            if (ops.toBoolean(res)) {
                return switch (mode) {
                    .find, .find_last => root_buf[3],
                    .find_index, .find_last_index => Value.fromNumber(@floatFromInt(i)),
                };
            }
            root_buf[3] = .undefined;
        }
    }
    return switch (mode) {
        .find, .find_last => .undefined,
        .find_index, .find_last_index => Value.fromNumber(-1),
    };
}

fn arrayFind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "find", .find);
}

fn arrayFindIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "findIndex", .find_index);
}

fn arrayFindLast(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "findLast", .find_last);
}

fn arrayFindLastIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arrayFindImpl(rt, this, args, "findLastIndex", .find_last_index);
}

fn arraySomeEveryImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime is_every: bool) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ o_val, arg(args, 0), this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const cb = try requireCallable(rt, root_buf[1]);
        for (0..len) |i| {
            if (i >= a.kind.array.items.len) continue;
            const elem = a.kind.array.items[i];
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            const b = ops.toBoolean(res);
            if (is_every and !b) return Value.fromBool(false);
            if (!is_every and b) return Value.fromBool(true);
        }
        return Value.fromBool(is_every);
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const cb = try requireCallable(rt, root_buf[1]);
    for (0..len) |i| {
        if (try object.has(rt, .{ .index = @intCast(i) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(i) });
            const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), o_val });
            const b = ops.toBoolean(res);
            if (is_every and !b) return Value.fromBool(false);
            if (!is_every and b) return Value.fromBool(true);
        }
    }
    return Value.fromBool(is_every);
}

fn arraySome(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arraySomeEveryImpl(rt, this, args, "some", false);
}

fn arrayEvery(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return arraySomeEveryImpl(rt, this, args, "every", true);
}

fn isConcatSpreadable(rt: *Runtime, v: Value) Error!bool {
    if (!v.isObject() and !v.isClosure() and !v.isNative()) return false;
    const r = try realm(rt);
    const spreadable = try object.get(rt, v, .{ .symbol = r.sym_is_concat_spreadable });
    if (!spreadable.isUndefined()) return ops.toBoolean(spreadable);
    return v.isObject() and v.asObject().kind == .array;
}

fn concatAppendItem(rt: *Runtime, out: *Object, item: Value, elem_root: *Value) Error!void {
    if (try isConcatSpreadable(rt, item)) {
        if (item.isObject() and item.asObject().kind == .array) {
            try rt.heap.appendElements(out, item.asObject().kind.array.items);
        } else {
            const len_f = try toLength(rt, try object.get(rt, item, try object.named(rt, "length")));
            const len: usize = @intFromFloat(len_f);
            for (0..len) |i| {
                if (!try object.has(rt, .{ .index = @intCast(i) }, item)) return rt.fail(.sparse_array);
                elem_root.* = try object.get(rt, item, .{ .index = @intCast(i) });
                try rt.heap.appendElement(out, elem_root.*);
                elem_root.* = .undefined;
            }
        }
    } else {
        try rt.heap.appendElement(out, item);
    }
}

fn arrayConcat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ o_val, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try concatAppendItem(rt, out, o_val, &root_buf[2]);
    for (args) |v| {
        try concatAppendItem(rt, out, v, &root_buf[2]);
    }
    return Value.fromObject(out);
}

fn arrayReverse(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        if (len > 1) try checkArrayMutate(rt, a, .{ .write_elements = true });
        var lo: usize = 0;
        while (lo < len / 2) : (lo += 1) {
            const hi = len - 1 - lo;
            const tmp = a.kind.array.items[lo];
            rt.heap.storeElement(a, lo, a.kind.array.items[hi]);
            rt.heap.storeElement(a, hi, tmp);
        }
        return o_val;
    }
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    var lo: usize = 0;
    while (lo < len / 2) : (lo += 1) {
        const hi = len - 1 - lo;
        const lo_k: object.Key = .{ .index = @intCast(lo) };
        const hi_k: object.Key = .{ .index = @intCast(hi) };
        const lo_exists = try object.has(rt, lo_k, o_val);
        if (lo_exists) root_buf[1] = try object.get(rt, o_val, lo_k);
        const hi_exists = try object.has(rt, hi_k, o_val);
        if (hi_exists) root_buf[2] = try object.get(rt, o_val, hi_k);
        if (lo_exists and hi_exists) {
            try object.setStrict(rt, o_val, lo_k, root_buf[2]);
            try object.setStrict(rt, o_val, hi_k, root_buf[1]);
        } else if (!lo_exists and hi_exists) {
            try object.setStrict(rt, o_val, lo_k, root_buf[2]);
            if (!try object.delete(rt, o_val, hi_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
        } else if (lo_exists and !hi_exists) {
            if (!try object.delete(rt, o_val, lo_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
            try object.setStrict(rt, o_val, hi_k, root_buf[1]);
        }
        root_buf[1] = .undefined;
        root_buf[2] = .undefined;
    }
    return o_val;
}

fn arrayAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const rel = try toIntegerOrInfinity(rt, arg(args, 0));
        const k = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
        if (k < 0 or k >= @as(f64, @floatFromInt(len))) return .undefined;
        return a.kind.array.items[@intFromFloat(k)];
    }
    var root_buf = [_]Value{o_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const rel = try toIntegerOrInfinity(rt, arg(args, 0));
    const k = if (rel >= 0) rel else len_f + rel;
    if (k < 0 or k >= len_f) return .undefined;
    return object.get(rt, o_val, .{ .index = @intFromFloat(k) });
}

fn arrayLastIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isObject() and this.asObject().kind == .array) {
        const items = this.asObject().kind.array.items;
        if (items.len == 0) return Value.fromNumber(-1);
        const needle = arg(args, 0);
        const len_f: f64 = @floatFromInt(items.len);
        const n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else len_f - 1;
        const k_f = if (n >= 0) @min(n, len_f - 1) else len_f + n;
        if (k_f < 0) return Value.fromNumber(-1);
        var k: usize = @intFromFloat(k_f);
        while (true) : (k -= 1) {
            if (ops.strictEquals(items[k], needle)) return Value.fromNumber(@floatFromInt(k));
            if (k == 0) break;
        }
        return Value.fromNumber(-1);
    }
    const o_val = try toObjectReceiver(rt, this);
    const needle = arg(args, 0);
    var root_buf = [_]Value{ o_val, needle };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f == 0) return Value.fromNumber(-1);
    const n = if (args.len >= 2) try toIntegerOrInfinity(rt, args[1]) else len_f - 1;
    const k_f = if (n >= 0) @min(n, len_f - 1) else len_f + n;
    if (k_f < 0) return Value.fromNumber(-1);
    var k: usize = @intFromFloat(k_f);
    while (true) : (k -= 1) {
        if (try object.has(rt, .{ .index = @intCast(k) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(k) });
            if (ops.strictEquals(elem, needle)) return Value.fromNumber(@floatFromInt(k));
        }
        if (k == 0) break;
    }
    return Value.fromNumber(-1);
}

fn arrayFill(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const val = arg(args, 0);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const start = if (arg(args, 1).isUndefined()) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
        const end = if (arg(args, 2).isUndefined()) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 2)), len);
        if (start < end) try checkArrayMutate(rt, a, .{ .write_elements = true });
        for (start..end) |i| rt.heap.storeElement(a, i, val);
        return o_val;
    }
    var root_buf = [_]Value{ o_val, val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const start = if (arg(args, 1).isUndefined()) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
    const end = if (arg(args, 2).isUndefined()) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 2)), len);
    for (start..end) |i| try object.setStrict(rt, o_val, .{ .index = @intCast(i) }, val);
    return o_val;
}

fn arrayShift(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const items = a.kind.array.items;
        if (items.len == 0) {
            try checkArrayMutate(rt, a, .{ .write_length = true });
            return .undefined;
        }
        try checkArrayMutate(rt, a, .{ .shrink = true, .write_elements = items.len > 1, .write_length = true });
        const first = items[0];
        for (1..items.len) |i| rt.heap.storeElement(a, i - 1, items[i]);
        rt.heap.shrinkElements(a, items.len - 1);
        return first;
    }
    var root_buf = [_]Value{ o_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    if (len_f == 0) {
        try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(0));
        return .undefined;
    }
    const len: usize = @intFromFloat(len_f);
    root_buf[1] = try object.get(rt, o_val, .{ .index = 0 });
    for (1..len) |i| {
        const from_k: object.Key = .{ .index = @intCast(i) };
        const to_k: object.Key = .{ .index = @intCast(i - 1) };
        if (try object.has(rt, from_k, o_val)) {
            root_buf[2] = try object.get(rt, o_val, from_k);
            try object.setStrict(rt, o_val, to_k, root_buf[2]);
            root_buf[2] = .undefined;
        } else {
            if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
        }
    }
    if (!try object.delete(rt, o_val, .{ .index = @intCast(len - 1) })) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(len - 1)));
    return root_buf[1];
}

fn arrayUnshift(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const old_len = a.kind.array.items.len;
        const ins_len = args.len;
        try checkArrayMutate(rt, a, .{
            .grow = ins_len > 0,
            .write_elements = ins_len > 0 and old_len > 0,
            .write_length = true,
        });
        if (ins_len > 0) {
            // Grow upfront so OOM leaves the array untouched.
            try rt.heap.appendElements(a, args);
            var i: usize = old_len;
            while (i > 0) {
                i -= 1;
                rt.heap.storeElement(a, i + ins_len, a.kind.array.items[i]);
            }
            for (args, 0..) |v, j| rt.heap.storeElement(a, j, v);
        }
        return Value.fromNumber(@floatFromInt(a.kind.array.items.len));
    }
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const ins_len = args.len;
    if (ins_len > 0) {
        if (len_f + @as(f64, @floatFromInt(ins_len)) > 9007199254740991.0) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Invalid array length" }});
        }
        var i: usize = @intFromFloat(len_f);
        while (i > 0) {
            i -= 1;
            const from_k: object.Key = .{ .index = @intCast(i) };
            const to_k: object.Key = .{ .index = @intCast(i + ins_len) };
            if (try object.has(rt, from_k, o_val)) {
                root_buf[1] = try object.get(rt, o_val, from_k);
                try object.setStrict(rt, o_val, to_k, root_buf[1]);
                root_buf[1] = .undefined;
            } else {
                if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
            }
        }
        for (args, 0..) |v, j| try object.setStrict(rt, o_val, .{ .index = @intCast(j) }, v);
    }
    const new_len = len_f + @as(f64, @floatFromInt(ins_len));
    try object.setStrict(rt, o_val, try object.named(rt, "length"), Value.fromNumber(new_len));
    return Value.fromNumber(new_len);
}

fn arraySplice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "splice");
    const len = a.kind.array.items.len;
    const actual_start: usize = if (args.len == 0) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, args[0]), len);
    const actual_delete: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        len - actual_start
    else blk: {
        const dc = try toIntegerOrInfinity(rt, args[1]);
        const max_dc: f64 = @floatFromInt(len - actual_start);
        break :blk @intFromFloat(@min(@max(dc, 0), max_dc));
    };
    const insert_items = if (args.len > 2) args[2..] else &[_]Value{};
    const insert_count = insert_items.len;
    try checkArrayMutate(rt, a, .{
        .grow = insert_count > actual_delete,
        .shrink = insert_count < actual_delete,
        .write_elements = insert_count > 0 or (insert_count < actual_delete and actual_start + actual_delete < len),
        .write_length = insert_count != actual_delete,
    });

    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.appendElements(out, a.kind.array.items[actual_start .. actual_start + actual_delete]);

    if (insert_count > actual_delete) {
        const delta = insert_count - actual_delete;
        // Grow upfront with the new items slice so OOM leaves `a` untouched.
        try rt.heap.appendElements(a, insert_items[0..delta]);
        var i: usize = len;
        while (i > actual_start + actual_delete) {
            i -= 1;
            rt.heap.storeElement(a, i + delta, a.kind.array.items[i]);
        }
    } else if (insert_count < actual_delete) {
        const tail_start = actual_start + actual_delete;
        for (tail_start..len) |i| {
            rt.heap.storeElement(a, i - actual_delete + insert_count, a.kind.array.items[i]);
        }
        rt.heap.shrinkElements(a, len - actual_delete + insert_count);
    }

    for (insert_items, 0..) |v, j| {
        rt.heap.storeElement(a, actual_start + j, v);
    }
    return Value.fromObject(out);
}

fn arraySort(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "sort");
    const cb: ?Value = if (args.len >= 1 and !args[0].isUndefined()) try requireCallable(rt, args[0]) else null;
    const len = a.kind.array.items.len;
    if (len <= 1) return this;
    try checkArrayMutate(rt, a, .{ .write_elements = true });

    const snap = try rt.heap.newArray(null);
    const tmp = try rt.heap.newArray(null);
    var root_buf = [_]Value{ this, cb orelse .undefined, Value.fromObject(snap), Value.fromObject(tmp), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (a.kind.array.items) |v| {
        if (!v.isUndefined()) try rt.heap.appendElement(snap, v);
    }
    const defined_count = snap.kind.array.items.len;
    if (defined_count > 1) {
        try rt.heap.appendElements(tmp, snap.kind.array.items);
        try mergeSortRange(rt, cb, snap, tmp, 0, defined_count, &root_buf[4], &root_buf[5]);
    }

    // Write back to `a` only after all comparisons succeed, handling comparator mutations safely.
    const cur_len = a.kind.array.items.len;
    const write_len = @min(len, cur_len);
    for (0..write_len) |i| {
        const v = if (i < defined_count) snap.kind.array.items[i] else Value.undefined;
        rt.heap.storeElement(a, i, v);
    }
    if (cur_len < len) {
        for (cur_len..len) |i| {
            const v = if (i < defined_count) snap.kind.array.items[i] else Value.undefined;
            try rt.heap.appendElement(a, v);
        }
    }
    return this;
}

fn mergeSortRange(
    rt: *Runtime,
    cb: ?Value,
    snap: *Object,
    tmp: *Object,
    lo: usize,
    hi: usize,
    root_a: *Value,
    root_b: *Value,
) Error!void {
    if (hi - lo <= 1) return;
    const mid = lo + (hi - lo) / 2;
    try mergeSortRange(rt, cb, snap, tmp, lo, mid, root_a, root_b);
    try mergeSortRange(rt, cb, snap, tmp, mid, hi, root_a, root_b);

    for (lo..hi) |k| rt.heap.storeElement(tmp, k, snap.kind.array.items[k]);

    var i = lo;
    var j = mid;
    var k = lo;
    while (i < mid and j < hi) : (k += 1) {
        const left_v = tmp.kind.array.items[i];
        const right_v = tmp.kind.array.items[j];
        const cmp = try sortCompare(rt, cb, left_v, right_v, root_a, root_b);
        if (cmp <= 0) {
            rt.heap.storeElement(snap, k, left_v);
            i += 1;
        } else {
            rt.heap.storeElement(snap, k, right_v);
            j += 1;
        }
    }
    while (i < mid) : ({
        i += 1;
        k += 1;
    }) rt.heap.storeElement(snap, k, tmp.kind.array.items[i]);
    while (j < hi) : ({
        j += 1;
        k += 1;
    }) rt.heap.storeElement(snap, k, tmp.kind.array.items[j]);
}

fn arrayReduceRight(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    var root_buf = [_]Value{ o_val, arg(args, 0), arg(args, 1) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const cb = try requireCallable(rt, root_buf[1]);
        const elems = a.kind.array.items;
        const len = elems.len;
        var idx: usize = len;
        if (args.len < 2) {
            if (len == 0) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
            idx = len - 1;
            root_buf[2] = elems[idx];
        }
        while (idx > 0) {
            idx -= 1;
            if (idx >= a.kind.array.items.len) continue;
            const elem = a.kind.array.items[idx];
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(idx)), o_val });
        }
        return root_buf[2];
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    var idx: usize = @intFromFloat(len_f);
    const cb = try requireCallable(rt, root_buf[1]);
    if (args.len < 2) {
        var found = false;
        while (idx > 0) {
            idx -= 1;
            if (try object.has(rt, .{ .index = @intCast(idx) }, o_val)) {
                root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(idx) });
                found = true;
                break;
            }
        }
        if (!found) return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty array with no initial value" }});
    }
    while (idx > 0) {
        idx -= 1;
        if (try object.has(rt, .{ .index = @intCast(idx) }, o_val)) {
            const elem = try object.get(rt, o_val, .{ .index = @intCast(idx) });
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(idx)), o_val });
        }
    }
    return root_buf[2];
}

fn flattenIntoArray(rt: *Runtime, out: *Object, src: *Object, depth_left: f64, rec_depth: u16) Error!void {
    if (rec_depth >= rt.limits.max_nesting_depth) return rt.limit(.nesting_depth);
    const items = src.kind.array.items;
    for (items) |elem| {
        if (depth_left > 0 and elem.isObject() and elem.asObject().kind == .array) {
            try flattenIntoArray(rt, out, elem.asObject(), depth_left - 1, rec_depth + 1);
        } else {
            try rt.heap.appendElement(out, elem);
        }
    }
}

fn arrayFlat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "flat");
    const depth = if (args.len >= 1 and !args[0].isUndefined()) try toIntegerOrInfinity(rt, args[0]) else 1.0;
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try flattenIntoArray(rt, out, a, depth, 0);
    return Value.fromObject(out);
}

fn arrayFlatMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "flatMap");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const len = a.kind.array.items.len;
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, cb, this_arg, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (0..len) |i| {
        const elem = if (i < a.kind.array.items.len) a.kind.array.items[i] else Value.undefined;
        const mapped = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        root_buf[4] = mapped;
        if (mapped.isObject() and mapped.asObject().kind == .array) {
            try rt.heap.appendElements(out, mapped.asObject().kind.array.items);
        } else {
            try rt.heap.appendElement(out, mapped);
        }
        root_buf[4] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayCopyWithin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const to = resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 0)), len);
        const from = resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
        const final_idx = if (arg(args, 2).isUndefined()) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 2)), len);
        const count = if (final_idx > from) @min(final_idx - from, len - to) else 0;
        if (count > 0) {
            try checkArrayMutate(rt, a, .{ .write_elements = true });
            if (from != to) {
                if (from < to and to < from + count) {
                    var i: usize = count;
                    while (i > 0) {
                        i -= 1;
                        rt.heap.storeElement(a, to + i, a.kind.array.items[from + i]);
                    }
                } else {
                    for (0..count) |i| {
                        rt.heap.storeElement(a, to + i, a.kind.array.items[from + i]);
                    }
                }
            }
        }
        return o_val;
    }
    var root_buf = [_]Value{ o_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const to = resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 0)), len);
    const from = resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
    const final_idx = if (arg(args, 2).isUndefined()) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 2)), len);
    const count = if (final_idx > from) @min(final_idx - from, len - to) else 0;
    if (count > 0 and from != to) {
        const back = from < to and to < from + count;
        for (0..count) |step| {
            const offset = if (back) count - 1 - step else step;
            const from_k: object.Key = .{ .index = @intCast(from + offset) };
            const to_k: object.Key = .{ .index = @intCast(to + offset) };
            if (try object.has(rt, from_k, o_val)) {
                root_buf[1] = try object.get(rt, o_val, from_k);
                try object.setStrict(rt, o_val, to_k, root_buf[1]);
                root_buf[1] = .undefined;
            } else {
                if (!try object.delete(rt, o_val, to_k)) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot delete property" }});
            }
        }
    }
    return o_val;
}

fn arrayToReversed(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ o_val, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        var i: usize = a.kind.array.items.len;
        while (i > 0) {
            i -= 1;
            try rt.heap.appendElement(out, a.kind.array.items[i]);
        }
        return Value.fromObject(out);
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    var i: usize = @intFromFloat(len_f);
    while (i > 0) {
        i -= 1;
        root_buf[2] = try object.get(rt, o_val, .{ .index = @intCast(i) });
        try rt.heap.appendElement(out, root_buf[2]);
        root_buf[2] = .undefined;
    }
    return Value.fromObject(out);
}

fn arrayToSorted(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "toSorted");
    const cb: ?Value = if (args.len >= 1 and !args[0].isUndefined()) try requireCallable(rt, args[0]) else null;
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    const len = a.kind.array.items.len;
    if (len == 0) return Value.fromObject(out);

    const snap = try rt.heap.newArray(null);
    const tmp = try rt.heap.newArray(null);
    var root_buf = [_]Value{ this, cb orelse .undefined, Value.fromObject(out), Value.fromObject(snap), Value.fromObject(tmp), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (a.kind.array.items) |v| {
        if (!v.isUndefined()) try rt.heap.appendElement(snap, v);
    }
    const defined_count = snap.kind.array.items.len;
    if (defined_count > 1) {
        try rt.heap.appendElements(tmp, snap.kind.array.items);
        try mergeSortRange(rt, cb, snap, tmp, 0, defined_count, &root_buf[5], &root_buf[6]);
    }

    try rt.heap.appendElements(out, snap.kind.array.items);
    for (defined_count..len) |_| {
        try rt.heap.appendElement(out, .undefined);
    }
    return Value.fromObject(out);
}

fn arrayToSpliced(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const a = try thisArray(rt, this, "toSpliced");
    const len = a.kind.array.items.len;
    const actual_start = if (args.len == 0) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, args[0]), len);
    const actual_delete: usize = if (args.len == 0)
        0
    else if (args.len == 1)
        len - actual_start
    else blk: {
        const dc = try toIntegerOrInfinity(rt, args[1]);
        if (dc <= 0) break :blk 0;
        const max_del: f64 = @floatFromInt(len - actual_start);
        break :blk @intFromFloat(@min(dc, max_del));
    };
    const insert_items = if (args.len > 2) args[2..] else &[_]Value{};

    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.appendElements(out, a.kind.array.items[0..actual_start]);
    if (insert_items.len > 0) try rt.heap.appendElements(out, insert_items);
    try rt.heap.appendElements(out, a.kind.array.items[actual_start + actual_delete .. len]);
    return Value.fromObject(out);
}

fn arrayWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o_val = try toObjectReceiver(rt, this);
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    const val = arg(args, 1);
    var root_buf = [_]Value{ o_val, val, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o_val.isObject() and o_val.asObject().kind == .array) {
        const a = o_val.asObject();
        const len = a.kind.array.items.len;
        const rel = try toIntegerOrInfinity(rt, arg(args, 0));
        const actual_f = if (rel < 0) @as(f64, @floatFromInt(len)) + rel else rel;
        if (!std.math.isFinite(actual_f) or actual_f < 0 or actual_f >= @as(f64, @floatFromInt(len))) {
            return rt.throw(.RangeError, &.{.{ .ascii = "Invalid index" }});
        }
        const actual_idx: usize = @intFromFloat(actual_f);
        try rt.heap.appendElements(out, a.kind.array.items);
        rt.heap.storeElement(out, actual_idx, val);
        return Value.fromObject(out);
    }
    const len_f = try toLength(rt, try object.get(rt, o_val, try object.named(rt, "length")));
    const rel = try toIntegerOrInfinity(rt, arg(args, 0));
    const actual_f = if (rel < 0) len_f + rel else rel;
    if (!std.math.isFinite(actual_f) or actual_f < 0 or actual_f >= len_f) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid index" }});
    }
    const actual_idx: usize = @intFromFloat(actual_f);
    const len: usize = @intFromFloat(len_f);
    for (0..len) |i| {
        if (i == actual_idx) {
            try rt.heap.appendElement(out, val);
        } else {
            root_buf[3] = try object.get(rt, o_val, .{ .index = @intCast(i) });
            try rt.heap.appendElement(out, root_buf[3]);
            root_buf[3] = .undefined;
        }
    }
    return Value.fromObject(out);
}

fn sortCompare(rt: *Runtime, cb: ?Value, x: Value, y: Value, root_a: *Value, root_b: *Value) Error!f64 {
    if (cb) |f| {
        const res = try rt.callCallable(f, .undefined, &.{ x, y });
        const v = try ops.toNumber(rt, res);
        return if (std.math.isNan(v)) 0 else v;
    }
    const xs = try toStringObj(rt, x);
    root_a.* = Value.fromString(xs);
    const ys = try toStringObj(rt, y);
    root_b.* = Value.fromString(ys);
    const ord = std.mem.order(u16, xs.units, ys.units);
    root_a.* = .undefined;
    root_b.* = .undefined;
    return switch (ord) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

// ---------------------------------------------------------------- String.prototype

const string_char_at: Native = .{ .name = "charAt", .length = 1, .call = stringCharAt };
const string_char_code_at: Native = .{ .name = "charCodeAt", .length = 1, .call = stringCharCodeAt };
const string_code_point_at: Native = .{ .name = "codePointAt", .length = 1, .call = stringCodePointAt };
const string_from_char_code: Native = .{ .name = "fromCharCode", .length = 1, .call = stringFromCharCode };
const string_from_code_point: Native = .{ .name = "fromCodePoint", .length = 1, .call = stringFromCodePoint };
const string_raw: Native = .{ .name = "raw", .length = 1, .call = stringRaw };
const string_slice: Native = .{ .name = "slice", .length = 2, .call = stringSlice };
const string_index_of: Native = .{ .name = "indexOf", .length = 1, .call = stringIndexOf };
const string_includes: Native = .{ .name = "includes", .length = 1, .call = stringIncludes };
const string_to_lower_case: Native = .{ .name = "toLowerCase", .call = stringToLowerCase };
const string_to_upper_case: Native = .{ .name = "toUpperCase", .call = stringToUpperCase };
const string_to_locale_lower_case: Native = .{ .name = "toLocaleLowerCase", .call = stringToLocaleLowerCase };
const string_to_locale_upper_case: Native = .{ .name = "toLocaleUpperCase", .call = stringToLocaleUpperCase };
const string_concat: Native = .{ .name = "concat", .length = 1, .call = stringConcat };
const string_split: Native = .{ .name = "split", .length = 2, .call = stringSplit };
const string_trim: Native = .{ .name = "trim", .call = stringTrim };
const string_trim_start: Native = .{ .name = "trimStart", .call = stringTrimStart };
const string_trim_end: Native = .{ .name = "trimEnd", .call = stringTrimEnd };
const string_starts_with: Native = .{ .name = "startsWith", .length = 1, .call = stringStartsWith };
const string_ends_with: Native = .{ .name = "endsWith", .length = 1, .call = stringEndsWith };
const string_repeat: Native = .{ .name = "repeat", .length = 1, .call = stringRepeat };
const string_pad_start: Native = .{ .name = "padStart", .length = 1, .call = stringPadStart };
const string_pad_end: Native = .{ .name = "padEnd", .length = 1, .call = stringPadEnd };
const string_substring: Native = .{ .name = "substring", .length = 2, .call = stringSubstring };
const string_last_index_of: Native = .{ .name = "lastIndexOf", .length = 1, .call = stringLastIndexOf };
const string_at: Native = .{ .name = "at", .length = 1, .call = stringAt };
const string_replace: Native = .{ .name = "replace", .length = 2, .call = stringReplace };
const string_replace_all: Native = .{ .name = "replaceAll", .length = 2, .call = stringReplaceAll };
const string_match: Native = .{ .name = "match", .length = 1, .call = stringMatch };
const string_match_all: Native = .{ .name = "matchAll", .length = 1, .call = stringMatchAll };
const string_search: Native = .{ .name = "search", .length = 1, .call = stringSearch };

fn thisString(rt: *Runtime, this: Value, name: []const u8) Error!*const heap_mod.String {
    return switch (this.unpack()) {
        .string => |s| s,
        .object => |o| if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isString()) o.kind.primitive_wrapper.asString() else unsupportedReceiver(rt, name),
        else => unsupportedReceiver(rt, name),
    };
}

fn requireStringCoercible(rt: *Runtime, this: Value) Error!*const heap_mod.String {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype method called on null or undefined" }});
    }
    return toStringObj(rt, this);
}

pub fn toStringObj(rt: *Runtime, v: Value) Error!*const heap_mod.String {
    if (v.isString()) return v.asString();
    var buf: ops.NumberBuf = undefined;
    const piece = try ops.toPiece(rt, v, &buf);
    return rt.heap.newString(&.{piece});
}

fn toStringUnits(rt: *Runtime, v: Value) Error![]const u16 {
    return (try toStringObj(rt, v)).units;
}

fn isJsWhitespace(u: u16) bool {
    return switch (u) {
        0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

fn stringCharAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "charAt");
    const pos = try toIntegerOrInfinity(rt, arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) {
        return Value.fromString(try rt.heap.newString(&.{}));
    }
    const i: usize = @intFromFloat(pos);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }}));
}

fn stringCharCodeAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const pos = try toIntegerOrInfinity(rt, arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(@floatFromInt(s.units[@intFromFloat(pos)])); // a UTF-16 code unit
}

fn stringCodePointAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const pos = try toIntegerOrInfinity(rt, arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.units.len))) return .undefined;
    const i: usize = @intFromFloat(pos);
    const first = s.units[i];
    if (first >= 0xD800 and first <= 0xDBFF and i + 1 < s.units.len) {
        const second = s.units[i + 1];
        if (second >= 0xDC00 and second <= 0xDFFF) {
            const cp: u32 = 0x10000 + ((@as(u32, first - 0xD800) << 10) | @as(u32, second - 0xDC00));
            return Value.fromNumber(@floatFromInt(cp));
        }
    }
    return Value.fromNumber(@floatFromInt(first));
}

fn stringFromCharCode(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len > rt.limits.max_string_length) return rt.limit(.string_length);
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(rt.gpa);
    try buf.ensureTotalCapacity(rt.gpa, args.len);
    for (args) |a| {
        const n = try ops.toNumber(rt, a);
        const u: u16 = @truncate(@as(u32, @bitCast(ops.toInt32(n))));
        buf.appendAssumeCapacity(u);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = buf.items }}));
}

fn stringFromCodePoint(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(rt.gpa);
    for (args) |a| {
        const n = try ops.toNumber(rt, a);
        if (!std.math.isFinite(n) or @trunc(n) != n or n < 0 or n > 0x10FFFF) {
            return rt.throw(.RangeError, &.{.{ .ascii = "Invalid code point" }});
        }
        const cp: u21 = @intFromFloat(n);
        if (cp <= 0xFFFF) {
            if (buf.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try buf.append(rt.gpa, @intCast(cp));
        } else {
            if (buf.items.len + 2 > rt.limits.max_string_length) return rt.limit(.string_length);
            const v = cp - 0x10000;
            try buf.append(rt.gpa, @intCast(0xD800 + (v >> 10)));
            try buf.append(rt.gpa, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = buf.items }}));
}

fn stringRaw(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const tmpl = arg(args, 0);
    if (tmpl.isUndefined() or tmpl.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const raw = try object.get(rt, tmpl, try object.named(rt, "raw"));
    if (raw.isUndefined() or raw.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var root_buf = [_]Value{ raw, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const len_val = try object.get(rt, raw, try object.named(rt, "length"));
    const literal_segments = try toLength(rt, len_val);
    if (literal_segments <= 0) return Value.fromString(try rt.heap.newString(&.{}));

    const max_len = rt.heap.max_string_length;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    var next_index: f64 = 0;
    while (next_index < literal_segments) : (next_index += 1) {
        const key: object.Key = if (next_index <= @as(f64, @floatFromInt(std.math.maxInt(u32))))
            .{ .index = @intFromFloat(next_index) }
        else
            try object.key(rt, Value.fromNumber(next_index));
        const seg_val = try object.get(rt, raw, key);
        const seg = try toStringObj(rt, seg_val);
        root_buf[1] = Value.fromString(seg);
        try appendUnits(rt, &out, seg.units);
        if (next_index + 1 == literal_segments) break;
        const sub_idx_f = next_index + 1;
        if (sub_idx_f < @as(f64, @floatFromInt(args.len))) {
            const sub_idx: usize = @intFromFloat(sub_idx_f);
            const sub = try toStringObj(rt, args[sub_idx]);
            root_buf[1] = Value.fromString(sub);
            try appendUnits(rt, &out, sub.units);
        }
        if (out.items.len > max_len) return rt.limit(.string_length);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringSlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisString(rt, this, "slice");
    const len = s.units.len;
    const from = if (arg(args, 0).isUndefined()) 0 else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 0)), len);
    const to = if (arg(args, 1).isUndefined()) len else resolveRelativeIndex(try toIntegerOrInfinity(rt, arg(args, 1)), len);
    if (from >= to) return Value.fromString(try rt.heap.newString(&.{}));
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[from..to] }}));
}

fn stringIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_obj = try toStringObj(rt, arg(args, 0));
    root_buf[1] = Value.fromString(search_obj);
    const pos = try toIntegerOrInfinity(rt, arg(args, 1));
    const len = s.units.len;
    const start: usize = if (pos <= 0) 0 else if (pos >= @as(f64, @floatFromInt(len))) len else @intFromFloat(pos);
    if (search_obj.units.len == 0) return Value.fromNumber(@floatFromInt(start));
    if (std.mem.indexOfPos(u16, s.units, start, search_obj.units)) |idx| return Value.fromNumber(@floatFromInt(idx));
    return Value.fromNumber(-1);
}

fn stringIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_arg = arg(args, 0);
    if (search_arg.isObject() and search_arg.asObject().kind == .regexp) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to String.prototype.includes must not be a regular expression" }});
    }
    const search_obj = try toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search_obj);
    const pos = try toIntegerOrInfinity(rt, arg(args, 1));
    const len = s.units.len;
    const start: usize = if (pos <= 0) 0 else if (pos >= @as(f64, @floatFromInt(len))) len else @intFromFloat(pos);
    if (search_obj.units.len == 0) return Value.fromBool(true);
    return Value.fromBool(std.mem.indexOfPos(u16, s.units, start, search_obj.units) != null);
}

/// Compatibility restriction: JavaScript case conversion is Unicode-aware, whereas
/// ZQJS currently implements ASCII-only case conversion and reports `Unsupported(builtin)`
/// for non-ASCII code units (`>= 0x80`) rather than silently diverging from JS.
fn asciiCase(rt: *Runtime, s: *const heap_mod.String, name: []const u8, comptime upper: bool) Error!Value {
    var stack_buf: [256]u16 = undefined;
    const heap_buf: []u16 = if (s.units.len > stack_buf.len) try rt.gpa.alloc(u16, s.units.len) else &.{};
    defer if (heap_buf.len > 0) rt.gpa.free(heap_buf);
    const out = if (s.units.len > stack_buf.len) heap_buf else stack_buf[0..s.units.len];
    for (s.units, 0..) |u, i| {
        if (u >= 0x80) return unsupportedReceiver(rt, name);
        out[i] = if (upper)
            if (u >= 'a' and u <= 'z') u - 32 else u
        else if (u >= 'A' and u <= 'Z') u + 32 else u;
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out }}));
}

fn stringToLowerCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toLowerCase", false);
}

fn stringToUpperCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toUpperCase", true);
}

fn stringToLocaleLowerCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toLocaleLowerCase", false);
}

fn stringToLocaleUpperCase(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    return asciiCase(rt, s, "toLocaleUpperCase", true);
}

fn stringConcat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    if (args.len == 0) return Value.fromString(s);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    try appendUnits(rt, &out, s.units);
    for (args) |a| {
        const part = try toStringObj(rt, a);
        root_buf[1] = Value.fromString(part);
        try appendUnits(rt, &out, part.units);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len = s.units.len;
    const rel = try toIntegerOrInfinity(rt, arg(args, 0));
    const k = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
    if (k < 0 or k >= @as(f64, @floatFromInt(len))) return .undefined;
    const i: usize = @intFromFloat(k);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }}));
}

fn stringSubstring(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const len_f: f64 = @floatFromInt(s.units.len);
    const int_start = try toIntegerOrInfinity(rt, arg(args, 0));
    const int_end = if (arg(args, 1).isUndefined()) len_f else try toIntegerOrInfinity(rt, arg(args, 1));
    const final_start = @min(@max(int_start, 0), len_f);
    const final_end = @min(@max(int_end, 0), len_f);
    const from: usize = @intFromFloat(@min(final_start, final_end));
    const to: usize = @intFromFloat(@max(final_start, final_end));
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[from..to] }}));
}

fn stringLastIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_obj = try toStringObj(rt, arg(args, 0));
    root_buf[1] = Value.fromString(search_obj);
    const num_pos = if (args.len < 2) std.math.nan(f64) else try ops.toNumber(rt, args[1]);
    const pos = if (std.math.isNan(num_pos)) std.math.inf(f64) else if (num_pos == 0) 0 else @trunc(num_pos);
    const start: usize = @intFromFloat(@min(@max(pos, 0), @as(f64, @floatFromInt(s.units.len))));
    if (search_obj.units.len == 0) return Value.fromNumber(@floatFromInt(start));
    if (search_obj.units.len > s.units.len) return Value.fromNumber(-1);
    var k: usize = @min(start, s.units.len - search_obj.units.len);
    while (true) : (k -= 1) {
        if (std.mem.eql(u16, s.units[k .. k + search_obj.units.len], search_obj.units)) return Value.fromNumber(@floatFromInt(k));
        if (k == 0) break;
    }
    return Value.fromNumber(-1);
}

fn stringStartsWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_arg = arg(args, 0);
    if (search_arg.isObject() and search_arg.asObject().kind == .regexp) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to String.prototype.startsWith must not be a regular expression" }});
    }
    const search_obj = try toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search_obj);
    const pos = try toIntegerOrInfinity(rt, arg(args, 1));
    const start: usize = @intFromFloat(@min(@max(pos, 0), @as(f64, @floatFromInt(s.units.len))));
    if (search_obj.units.len == 0) return Value.fromBool(true);
    if (s.units.len - start < search_obj.units.len) return Value.fromBool(false);
    return Value.fromBool(std.mem.eql(u16, s.units[start .. start + search_obj.units.len], search_obj.units));
}

fn stringEndsWith(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const search_arg = arg(args, 0);
    if (search_arg.isObject() and search_arg.asObject().kind == .regexp) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to String.prototype.endsWith must not be a regular expression" }});
    }
    const search_obj = try toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search_obj);
    const len_f: f64 = @floatFromInt(s.units.len);
    const pos = if (arg(args, 1).isUndefined()) len_f else try toIntegerOrInfinity(rt, arg(args, 1));
    const end: usize = @intFromFloat(@min(@max(pos, 0), len_f));
    if (search_obj.units.len > end) return Value.fromBool(false);
    return Value.fromBool(std.mem.eql(u16, s.units[end - search_obj.units.len .. end], search_obj.units));
}

fn stringTrimImpl(rt: *Runtime, this: Value, _: []const u8, trim_start: bool, trim_end: bool) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var start: usize = 0;
    var end: usize = s.units.len;
    if (trim_start) while (start < end and isJsWhitespace(s.units[start])) {
        start += 1;
    };
    if (trim_end) while (end > start and isJsWhitespace(s.units[end - 1])) {
        end -= 1;
    };
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[start..end] }}));
}

fn stringTrim(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return stringTrimImpl(rt, this, "trim", true, true);
}

fn stringTrimStart(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return stringTrimImpl(rt, this, "trimStart", true, false);
}

fn stringTrimEnd(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return stringTrimImpl(rt, this, "trimEnd", false, true);
}

fn stringRepeat(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try requireStringCoercible(rt, this);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const n = try toIntegerOrInfinity(rt, arg(args, 0));
    if (n < 0 or n == std.math.inf(f64)) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid count value" }});
    if (n == 0 or s.units.len == 0) return Value.fromString(try rt.heap.newString(&.{}));
    const max_len = rt.heap.max_string_length;
    if (n > @as(f64, @floatFromInt(max_len))) return rt.limit(.string_length);
    const count: usize = @intFromFloat(n);
    const total = std.math.mul(usize, s.units.len, count) catch return rt.limit(.string_length);
    if (total > max_len) return rt.limit(.string_length);

    const buf = try rt.gpa.alloc(u16, total);
    defer rt.gpa.free(buf);
    for (0..count) |i| {
        @memcpy(buf[i * s.units.len ..][0..s.units.len], s.units);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = buf }}));
}

fn stringPadImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime is_start: bool) Error!Value {
    const s = try requireStringCoercible(rt, this);
    const s_val = Value.fromString(s);
    var root_buf = [_]Value{ s_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const max_len_f = try toIntegerOrInfinity(rt, arg(args, 0));
    if (max_len_f <= @as(f64, @floatFromInt(s.units.len))) return s_val;
    const filler: []const u16 = if (arg(args, 1).isUndefined())
        &.{' '}
    else blk: {
        const f_obj = try toStringObj(rt, arg(args, 1));
        root_buf[1] = Value.fromString(f_obj);
        break :blk f_obj.units;
    };
    if (filler.len == 0) return s_val;
    const max_str = rt.heap.max_string_length;
    if (max_len_f > @as(f64, @floatFromInt(max_str))) return rt.limit(.string_length);
    const target_len: usize = @intFromFloat(max_len_f);
    const pad_len = target_len - s.units.len;

    const pad_buf = try rt.gpa.alloc(u16, pad_len);
    defer rt.gpa.free(pad_buf);
    var filled: usize = 0;
    while (filled < pad_len) {
        const chunk = @min(filler.len, pad_len - filled);
        @memcpy(pad_buf[filled..][0..chunk], filler[0..chunk]);
        filled += chunk;
    }
    const pad_piece: heap_mod.Piece = .{ .utf16 = pad_buf };
    const orig_piece: heap_mod.Piece = .{ .utf16 = s.units };
    return Value.fromString(try rt.heap.newString(if (is_start) &.{ pad_piece, orig_piece } else &.{ orig_piece, pad_piece }));
}

fn stringPadStart(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringPadImpl(rt, this, args, "padStart", true);
}

fn stringPadEnd(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringPadImpl(rt, this, args, "padEnd", false);
}

fn stringSplit(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.split called on null or undefined" }});
    }
    const sep_arg = arg(args, 0);
    if (!sep_arg.isUndefined() and !sep_arg.isNull()) {
        const r = try realm(rt);
        if (try object.getMethod(rt, sep_arg, .{ .symbol = r.sym_split })) |splitter| {
            return rt.callCallable(splitter, sep_arg, &.{ this, arg(args, 1) });
        }
    }
    const s = try toStringObj(rt, this);
    const s_val = Value.fromString(s);
    var root_buf = [_]Value{ s_val, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const lim: u32 = if (arg(args, 1).isUndefined()) std.math.maxInt(u32) else ops.toUint32(try ops.toNumber(rt, arg(args, 1)));
    const r = try realm(rt);

    if (sep_arg.isUndefined()) {
        const out = try rt.heap.newArray(r.array_prototype);
        if (lim == 0) return Value.fromObject(out);
        root_buf[2] = Value.fromObject(out);
        try rt.heap.appendElement(out, s_val);
        return Value.fromObject(out);
    }

    const sep = try toStringObj(rt, sep_arg);
    root_buf[1] = Value.fromString(sep);

    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[2] = Value.fromObject(out);
    if (lim == 0) return Value.fromObject(out);

    if (sep.units.len == 0) {
        const count = @min(s.units.len, lim);
        for (0..count) |i| {
            const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }});
            root_buf[3] = Value.fromString(ch);
            try rt.heap.appendElement(out, root_buf[3]);
            root_buf[3] = .undefined;
        }
        return Value.fromObject(out);
    }

    if (s.units.len == 0) {
        try rt.heap.appendElement(out, s_val);
        return Value.fromObject(out);
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u16, s.units, pos, sep.units)) |idx| {
        const part = try rt.heap.newString(&.{.{ .utf16 = s.units[pos..idx] }});
        root_buf[3] = Value.fromString(part);
        try rt.heap.appendElement(out, root_buf[3]);
        root_buf[3] = .undefined;
        if (out.kind.array.items.len == lim) return Value.fromObject(out);
        pos = idx + sep.units.len;
    }
    const tail = try rt.heap.newString(&.{.{ .utf16 = s.units[pos..] }});
    root_buf[3] = Value.fromString(tail);
    try rt.heap.appendElement(out, root_buf[3]);
    return Value.fromObject(out);
}

fn appendUnits(rt: *Runtime, out: *std.ArrayList(u16), units: []const u16) Error!void {
    const max_len = rt.heap.max_string_length;
    if (units.len > max_len or out.items.len > max_len - units.len) return rt.limit(.string_length);
    try out.appendSlice(rt.gpa, units);
}

fn expandReplacement(
    rt: *Runtime,
    out: *std.ArrayList(u16),
    s_units: []const u16,
    pos: usize,
    match_len: usize,
    repl_units: []const u16,
) Error!void {
    var i: usize = 0;
    while (i < repl_units.len) {
        if (repl_units[i] == '$' and i + 1 < repl_units.len) {
            switch (repl_units[i + 1]) {
                '$' => {
                    try appendUnits(rt, out, &.{'$'});
                    i += 2;
                    continue;
                },
                '&' => {
                    try appendUnits(rt, out, s_units[pos .. pos + match_len]);
                    i += 2;
                    continue;
                },
                '`' => {
                    try appendUnits(rt, out, s_units[0..pos]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try appendUnits(rt, out, s_units[pos + match_len ..]);
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try appendUnits(rt, out, repl_units[i .. i + 1]);
        i += 1;
    }
}

fn stringReplaceImpl(rt: *Runtime, this: Value, args: []const Value, _: []const u8, comptime is_all: bool) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.replace called on null or undefined" }});
    }
    const search_arg = arg(args, 0);
    if (!search_arg.isUndefined() and !search_arg.isNull()) {
        if (is_all and search_arg.isObject() and search_arg.asObject().kind == .regexp) {
            const flags_val = try object.get(rt, search_arg, try object.named(rt, "flags"));
            if (flags_val.isUndefined() or flags_val.isNull()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.replaceAll called with a non-global RegExp argument" }});
            }
            const flags_s = try toStringObj(rt, flags_val);
            if (std.mem.indexOfScalar(u16, flags_s.units, 'g') == null) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.replaceAll called with a non-global RegExp argument" }});
            }
        }
        const r = try realm(rt);
        if (try object.getMethod(rt, search_arg, .{ .symbol = r.sym_replace })) |replacer| {
            return rt.callCallable(replacer, search_arg, &.{ this, arg(args, 1) });
        }
    }
    const s = try toStringObj(rt, this);
    const s_val = Value.fromString(s);
    var root_buf = [_]Value{ s_val, .undefined, arg(args, 1), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const search = try toStringObj(rt, search_arg);
    root_buf[1] = Value.fromString(search);
    const repl_arg = arg(args, 1);
    const is_func = repl_arg.isNative() or repl_arg.isClosure();

    const repl_str: ?*const heap_mod.String = if (!is_func) blk: {
        const rs = try toStringObj(rt, repl_arg);
        root_buf[3] = Value.fromString(rs);
        break :blk rs;
    } else null;

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    if (!is_all) {
        const pos = if (search.units.len == 0) 0 else std.mem.indexOf(u16, s.units, search.units) orelse return s_val;
        try appendUnits(rt, &out, s.units[0..pos]);
        if (is_func) {
            const matched = try rt.heap.newString(&.{.{ .utf16 = s.units[pos .. pos + search.units.len] }});
            root_buf[4] = Value.fromString(matched);
            const res = try rt.callCallable(repl_arg, .undefined, &.{ Value.fromString(matched), Value.fromNumber(@floatFromInt(pos)), s_val });
            const rs = try toStringObj(rt, res);
            root_buf[4] = Value.fromString(rs);
            try appendUnits(rt, &out, rs.units);
        } else {
            try expandReplacement(rt, &out, s.units, pos, search.units.len, repl_str.?.units);
        }
        try appendUnits(rt, &out, s.units[pos + search.units.len ..]);
        return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
    }

    if (search.units.len == 0) {
        const empty_s: ?*const heap_mod.String = if (is_func) blk: {
            const es = try rt.heap.newString(&.{});
            root_buf[3] = Value.fromString(es);
            break :blk es;
        } else null;
        for (0..s.units.len + 1) |pos| {
            if (pos > 0) try appendUnits(rt, &out, s.units[pos - 1 .. pos]);
            if (is_func) {
                const res = try rt.callCallable(repl_arg, .undefined, &.{ Value.fromString(empty_s.?), Value.fromNumber(@floatFromInt(pos)), s_val });
                const rs = try toStringObj(rt, res);
                root_buf[4] = Value.fromString(rs);
                try appendUnits(rt, &out, rs.units);
            } else {
                try expandReplacement(rt, &out, s.units, pos, 0, repl_str.?.units);
            }
        }
        return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
    }

    var pos: usize = 0;
    while (std.mem.indexOfPos(u16, s.units, pos, search.units)) |idx| {
        try appendUnits(rt, &out, s.units[pos..idx]);
        if (is_func) {
            const matched = try rt.heap.newString(&.{.{ .utf16 = s.units[idx .. idx + search.units.len] }});
            root_buf[4] = Value.fromString(matched);
            const res = try rt.callCallable(repl_arg, .undefined, &.{ Value.fromString(matched), Value.fromNumber(@floatFromInt(idx)), s_val });
            const rs = try toStringObj(rt, res);
            root_buf[4] = Value.fromString(rs);
            try appendUnits(rt, &out, rs.units);
        } else {
            try expandReplacement(rt, &out, s.units, idx, search.units.len, repl_str.?.units);
        }
        pos = idx + search.units.len;
    }
    try appendUnits(rt, &out, s.units[pos..]);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringReplace(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringReplaceImpl(rt, this, args, "replace", false);
}

fn stringReplaceAll(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return stringReplaceImpl(rt, this, args, "replaceAll", true);
}

// ---------------------------------------------------------------- Object, Array

const object_keys: Native = .{ .name = "keys", .length = 1, .call = objectKeys };
const object_values: Native = .{ .name = "values", .length = 1, .call = objectValues };
const object_entries: Native = .{ .name = "entries", .length = 1, .call = objectEntries };
const object_assign: Native = .{ .name = "assign", .length = 2, .call = objectAssign };
const object_create: Native = .{ .name = "create", .length = 2, .call = objectCreate };
const object_get_prototype_of: Native = .{ .name = "getPrototypeOf", .length = 1, .call = objectGetPrototypeOf };
const object_define_property: Native = .{ .name = "defineProperty", .length = 3, .call = objectDefineProperty };
const object_define_properties: Native = .{ .name = "defineProperties", .length = 2, .call = objectDefineProperties };
const object_get_own_property_descriptor: Native = .{ .name = "getOwnPropertyDescriptor", .length = 2, .call = objectGetOwnPropertyDescriptor };
const object_get_own_property_descriptors: Native = .{ .name = "getOwnPropertyDescriptors", .length = 1, .call = objectGetOwnPropertyDescriptors };
const object_get_own_property_symbols: Native = .{ .name = "getOwnPropertySymbols", .length = 1, .call = objectGetOwnPropertySymbols };
const object_get_own_property_names: Native = .{ .name = "getOwnPropertyNames", .length = 1, .call = objectGetOwnPropertyNames };
const object_set_prototype_of: Native = .{ .name = "setPrototypeOf", .length = 2, .call = objectSetPrototypeOf };
const object_prevent_extensions: Native = .{ .name = "preventExtensions", .length = 1, .call = objectPreventExtensions };
const object_is_extensible: Native = .{ .name = "isExtensible", .length = 1, .call = objectIsExtensible };
const object_seal: Native = .{ .name = "seal", .length = 1, .call = objectSeal };
const object_is_sealed: Native = .{ .name = "isSealed", .length = 1, .call = objectIsSealed };
const object_freeze: Native = .{ .name = "freeze", .length = 1, .call = objectFreeze };
const object_is_frozen: Native = .{ .name = "isFrozen", .length = 1, .call = objectIsFrozen };
const object_has_own: Native = .{ .name = "hasOwn", .length = 2, .call = objectHasOwn };
const object_is: Native = .{ .name = "is", .length = 2, .call = objectIs };
const object_from_entries: Native = .{ .name = "fromEntries", .length = 1, .call = objectFromEntries };
const object_group_by: Native = .{ .name = "groupBy", .length = 2, .call = objectGroupBy };
const object_proto_has_own_property: Native = .{ .name = "hasOwnProperty", .length = 1, .call = objectProtoHasOwnProperty };
const object_proto_is_prototype_of: Native = .{ .name = "isPrototypeOf", .length = 1, .call = objectProtoIsPrototypeOf };
const object_proto_property_is_enumerable: Native = .{ .name = "propertyIsEnumerable", .length = 1, .call = objectProtoPropertyIsEnumerable };
const array_is_array: Native = .{ .name = "isArray", .length = 1, .call = arrayIsArray };
const array_from: Native = .{ .name = "from", .length = 1, .call = arrayFrom };
const array_from_async: Native = .{ .name = "fromAsync", .length = 1, .call = arrayFromAsync };
const array_of: Native = .{ .name = "of", .call = arrayOf };
const number_is_integer: Native = .{ .name = "isInteger", .length = 1, .call = numberIsInteger };
const number_is_finite: Native = .{ .name = "isFinite", .length = 1, .call = numberIsFinite };
const number_is_nan: Native = .{ .name = "isNaN", .length = 1, .call = numberIsNaN };
const number_is_safe_integer: Native = .{ .name = "isSafeInteger", .length = 1, .call = numberIsSafeInteger };

fn objectKeys(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{Value.fromObject(out)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (arg(args, 0).unpack()) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean, .number, .bigint, .symbol, .native => {},
        .closure => |c| {
            const keys = try object.ownKeysClosure(rt, c);
            defer rt.gpa.free(keys);
            for (keys) |k| try pushKey(rt, out, k);
        },
        .string => |s| for (0..s.units.len) |i| try pushKey(rt, out, .{ .index = @intCast(i) }),
        .object => |o| {
            const keys = try object.ownKeys(rt, o);
            defer rt.gpa.free(keys);
            const key_vals = try rt.gpa.alloc(Value, keys.len);
            defer rt.gpa.free(key_vals);
            for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
            var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
            try key_roots.register(rt);
            defer key_roots.unregister(rt);
            for (keys) |k| try pushKey(rt, out, k);
        },
    }
    return Value.fromObject(out);
}

fn pushKey(rt: *Runtime, out: *Object, k: object.Key) Error!void {
    const s = switch (k) {
        .atom => |a| a,
        .index => |i| blk: {
            var buf: [10]u8 = undefined;
            break :blk try rt.heap.ascii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
        .symbol => unreachable,
    };
    try rt.heap.appendElement(out, Value.fromString(s));
}

fn objectGetOwnPropertySymbols(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const v = arg(args, 0);
    if (v.isUndefined() or v.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ v, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const syms: []*heap_mod.Symbol = switch (v.unpack()) {
        .object => |o| try object.ownSymbolKeys(rt, o, true),
        .closure => |c| try object.ownSymbolKeysClosure(rt, c, true),
        else => &.{},
    };
    defer rt.gpa.free(syms);
    for (syms) |sym| {
        try rt.heap.appendElement(out, Value.fromSymbol(sym));
    }
    return Value.fromObject(out);
}

fn objectCreate(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const proto: ?*Object = switch (arg(args, 0).unpack()) {
        .object => |o| o,
        .null => null,
        // A function is an object in node; ZQJS functions aren't (yet).
        .native, .closure => return rt.fail(.function_properties),
        else => return rt.throw(.TypeError, &.{.{ .ascii = "Object prototype may only be an Object or null" }}),
    };
    const out = try rt.heap.newObject(proto);
    const out_val: Value = Value.fromObject(out);
    if (args.len > 1 and !args[1].isUndefined()) {
        var root_buf = [_]Value{out_val};
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        _ = try objectDefineProperties(rt, .undefined, &.{ out_val, args[1] });
    }
    return out_val;
}

fn objectGetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const v = arg(args, 0);
    return switch (v.unpack()) {
        .undefined, .null => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean => Value.fromObject(r.boolean_prototype),
        .number => Value.fromObject(r.number_prototype),
        .string => Value.fromObject(r.string_prototype),
        .symbol => Value.fromObject(r.symbol_prototype),
        .bigint => Value.fromObject(r.bigint_prototype),
        .native, .closure, .object => object.getPrototypeOfValue(rt, v),
    };
}

fn sameValue(a: Value, b: Value) bool {
    if (a.isNumber() and b.isNumber()) {
        if (std.math.isNan(a.asNumber()) and std.math.isNan(b.asNumber())) return true;
        return @as(u64, @bitCast(a.asNumber())) == @as(u64, @bitCast(b.asNumber()));
    }
    return sameValueZero(a, b);
}

fn descriptorToObject(rt: *Runtime, p: heap_mod.Property) Error!Value {
    const r = try realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{ Value.fromObject(out), p.value, p.setter };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (p.is_accessor) {
        try rt.heap.storeProperty(out, try rt.heap.internAscii("get"), p.value);
        try rt.heap.storeProperty(out, try rt.heap.internAscii("set"), p.setter);
    } else {
        try rt.heap.storeProperty(out, try rt.heap.internAscii("value"), p.value);
        try rt.heap.storeProperty(out, try rt.heap.internAscii("writable"), Value.fromBool(p.writable));
    }
    try rt.heap.storeProperty(out, try rt.heap.internAscii("enumerable"), Value.fromBool(p.enumerable));
    try rt.heap.storeProperty(out, try rt.heap.internAscii("configurable"), Value.fromBool(p.configurable));
    return Value.fromObject(out);
}

fn getOwnPropertyRaw(rt: *Runtime, target: Value, k: object.Key) Error!?heap_mod.Property {
    switch (target.unpack()) {
        .object => |o| {
            switch (o.kind) {
                .array => |elements| switch (k) {
                    .index => |i| return if (i < elements.items.len) .{
                        .value = elements.items[i],
                        .writable = o.array_elements_writable,
                        .configurable = o.array_elements_configurable,
                    } else null,
                    .atom => if (object.isNamed(k, "length")) {
                        return .{
                            .value = Value.fromNumber(@floatFromInt(elements.items.len)),
                            .enumerable = false,
                            .writable = o.array_length_writable,
                            .configurable = false,
                        };
                    },
                    .symbol => {},
                },
                .regexp => |re| if (object.isNamed(k, "lastIndex")) {
                    return .{
                        .value = re.last_index,
                        .enumerable = false,
                        .writable = o.regexp_last_index_writable,
                        .configurable = false,
                    };
                },
                .module_namespace => |ns| {
                    if (k == .atom) {
                        for (ns.entries) |e| {
                            if (e.name == k.atom) {
                                const v = e.cell.value orelse return rt.throw(.ReferenceError, &.{
                                    .{ .ascii = "Cannot access '" },
                                    .{ .utf16 = e.name.units },
                                    .{ .ascii = "' before initialization" },
                                });
                                return .{ .value = v, .enumerable = true, .writable = true, .configurable = false };
                            }
                        }
                    }
                },
                .typed_array => |ta| {
                    if (object.canonicalNumericIndex(k)) |n| {
                        if (object.validIntegerIndex(ta, n)) |idx| {
                            return .{
                                .value = try object.readTypedArrayElement(rt, ta, idx),
                                .enumerable = true,
                                .writable = true,
                                .configurable = true,
                            };
                        }
                        return null;
                    }
                },
                .proxy => return proxyGetOwnPropertyDescriptor(rt, o, k),
                .primitive_wrapper => |pv| if (pv.isString()) {
                    const s = pv.asString();
                    switch (k) {
                        .index => |i| if (i < s.units.len) {
                            const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }});
                            return .{ .value = Value.fromString(ch), .writable = false, .configurable = false };
                        },
                        .atom => if (object.isNamed(k, "length")) {
                            return .{ .value = Value.fromNumber(@floatFromInt(s.units.len)), .enumerable = false, .writable = false, .configurable = false };
                        },
                        .symbol => {},
                    }
                },
                .ordinary, .map, .set, .iterator, .promise, .generator, .array_buffer, .data_view, .weak_map, .weak_set, .date => {},
            }
            if (o.props.count() > 0) {
                if (o.props.get(try object.propKey(rt, k))) |p| return p;
            }
            if (o.builtin == .global and k == .atom) {
                return globalOwnProp(rt, k.atom);
            }
            return null;
        },
        .closure => |c| {
            if (c.meta) |m| if (m.props.count() > 0) {
                if (m.props.get(try object.propKey(rt, k))) |p| return p;
            };
            if (object.isNamed(k, "length") and !(c.meta != null and c.meta.?.length_deleted)) return .{
                .value = Value.fromNumber(@floatFromInt(closureLength(c))),
                .enumerable = false,
                .writable = false,
                .configurable = if (c.meta) |m| m.length_configurable else true,
            };
            if (object.isNamed(k, "name") and !(c.meta != null and c.meta.?.name_deleted)) return .{
                .value = Value.fromString(try closureName(rt, c)),
                .enumerable = false,
                .writable = false,
                .configurable = if (c.meta) |m| m.name_configurable else true,
            };
            if (object.isNamed(k, "prototype")) {
                const proto_w = if (c.meta) |m| m.prototype_writable else true;
                if (c.meta) |m| if (m.prototype) |p| {
                    return .{ .value = p, .enumerable = false, .writable = proto_w, .configurable = false };
                };
                if (hasAutoPrototype(c)) {
                    const p = try materializeClosurePrototype(rt, @constCast(c));
                    return .{ .value = Value.fromObject(p), .enumerable = false, .writable = proto_w, .configurable = false };
                }
            }
            return null;
        },
        .string => |s| switch (k) {
            .index => |i| if (i < s.units.len) {
                const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i..][0..1] }});
                return .{ .value = Value.fromString(ch), .writable = false, .configurable = false };
            },
            .atom => if (object.isNamed(k, "length")) {
                return .{ .value = Value.fromNumber(@floatFromInt(s.units.len)), .enumerable = false, .writable = false, .configurable = false };
            },
            .symbol => {},
        },
        .native => |n| {
            if (object.isNamed(k, "length") and !rt.isNativePropDeleted(n, true)) return .{ .value = Value.fromNumber(@floatFromInt(n.length)), .enumerable = false, .writable = false };
            if (object.isNamed(k, "name") and !rt.isNativePropDeleted(n, false)) return .{ .value = Value.fromString(try rt.heap.ascii(n.name)), .enumerable = false, .writable = false };
            if (try namespaceObject(rt, n)) |ns| return ns.props.get(try object.propKey(rt, k));
        },
        else => {},
    }
    return null;
}

fn objectGetOwnPropertyDescriptor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const k = try object.key(rt, arg(args, 1));
    const p = (try getOwnPropertyRaw(rt, target, k)) orelse return .undefined;
    return descriptorToObject(rt, p);
}

fn objectGetOwnPropertyDescriptors(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const r = try realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{ target, Value.fromObject(out), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (target.isObjectLike()) {
        const keys = try ownKeysAllValue(rt, target);
        defer rt.gpa.free(keys);
        const key_vals = try rt.gpa.alloc(Value, keys.len);
        defer rt.gpa.free(key_vals);
        for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
        var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
        try key_roots.register(rt);
        defer key_roots.unregister(rt);

        for (keys) |k| {
            if (try getOwnPropertyRaw(rt, target, k)) |p| {
                const desc = try descriptorToObject(rt, p);
                root_buf[2] = desc;
                const pk = try object.propKey(rt, k);
                try rt.heap.definePropKey(out, pk, .{ .value = desc });
                root_buf[2] = .undefined;
            }
        }
    }
    return Value.fromObject(out);
}

fn keyToRootValue(k: object.Key) Value {
    return switch (k) {
        .atom => |a| Value.fromString(a),
        .symbol => |s| Value.fromSymbol(s),
        .index => .undefined,
    };
}

const ParsedDesc = struct {
    has_enum: bool = false,
    enum_val: bool = false,
    has_conf: bool = false,
    conf_val: bool = false,
    has_val: bool = false,
    val: Value = .undefined,
    has_writ: bool = false,
    writ_val: bool = false,
    has_get: bool = false,
    get_val: Value = .undefined,
    has_set: bool = false,
    set_val: Value = .undefined,

    fn isData(d: ParsedDesc) bool {
        return d.has_val or d.has_writ;
    }

    fn isAccessor(d: ParsedDesc) bool {
        return d.has_get or d.has_set;
    }

    fn toCompleteProperty(d: ParsedDesc) heap_mod.Property {
        if (d.isAccessor()) {
            return .{
                .is_accessor = true,
                .value = if (d.has_get) d.get_val else .undefined,
                .setter = if (d.has_set) d.set_val else .undefined,
                .enumerable = if (d.has_enum) d.enum_val else false,
                .configurable = if (d.has_conf) d.conf_val else false,
                .writable = false,
            };
        }
        return .{
            .is_accessor = false,
            .value = if (d.has_val) d.val else .undefined,
            .writable = if (d.has_writ) d.writ_val else false,
            .enumerable = if (d.has_enum) d.enum_val else false,
            .configurable = if (d.has_conf) d.conf_val else false,
        };
    }
};

fn parsePropertyDescriptor(rt: *Runtime, desc: Value) Error!ParsedDesc {
    if (!desc.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Property description must be an object" }});
    }
    var out: ParsedDesc = .{};
    var root_buf = [_]Value{ desc, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    out.has_enum = try object.has(rt, .{ .atom = try rt.heap.internAscii("enumerable") }, desc);
    if (out.has_enum) out.enum_val = ops.toBoolean(try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("enumerable") }));
    out.has_conf = try object.has(rt, .{ .atom = try rt.heap.internAscii("configurable") }, desc);
    if (out.has_conf) out.conf_val = ops.toBoolean(try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("configurable") }));

    out.has_val = try object.has(rt, .{ .atom = try rt.heap.internAscii("value") }, desc);
    if (out.has_val) {
        out.val = try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("value") });
        root_buf[1] = out.val;
    }
    out.has_writ = try object.has(rt, .{ .atom = try rt.heap.internAscii("writable") }, desc);
    if (out.has_writ) out.writ_val = ops.toBoolean(try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("writable") }));

    out.has_get = try object.has(rt, .{ .atom = try rt.heap.internAscii("get") }, desc);
    if (out.has_get) {
        out.get_val = try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("get") });
        root_buf[2] = out.get_val;
        if (!out.get_val.isUndefined() and !out.get_val.isFunction()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Getter must be a function" }});
        }
    }

    out.has_set = try object.has(rt, .{ .atom = try rt.heap.internAscii("set") }, desc);
    if (out.has_set) {
        out.set_val = try object.get(rt, desc, .{ .atom = try rt.heap.internAscii("set") });
        root_buf[3] = out.set_val;
        if (!out.set_val.isUndefined() and !out.set_val.isFunction()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Setter must be a function" }});
        }
    }

    if (out.isData() and out.isAccessor()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Invalid property descriptor. Cannot both specify accessors and a value or writable attribute" }});
    }
    return out;
}

fn parsedDescToObject(rt: *Runtime, d: ParsedDesc) Error!Value {
    const r = try realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{ Value.fromObject(out), d.val, d.get_val, d.set_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (d.has_val) try rt.heap.storeProperty(out, try rt.heap.internAscii("value"), d.val);
    if (d.has_writ) try rt.heap.storeProperty(out, try rt.heap.internAscii("writable"), Value.fromBool(d.writ_val));
    if (d.has_get) try rt.heap.storeProperty(out, try rt.heap.internAscii("get"), d.get_val);
    if (d.has_set) try rt.heap.storeProperty(out, try rt.heap.internAscii("set"), d.set_val);
    if (d.has_enum) try rt.heap.storeProperty(out, try rt.heap.internAscii("enumerable"), Value.fromBool(d.enum_val));
    if (d.has_conf) try rt.heap.storeProperty(out, try rt.heap.internAscii("configurable"), Value.fromBool(d.conf_val));
    return Value.fromObject(out);
}

fn isCompatiblePropertyDescriptor(d: ParsedDesc, cur: heap_mod.Property) bool {
    if (!cur.configurable) {
        if (d.has_conf and d.conf_val) return false;
        if (d.has_enum and d.enum_val != cur.enumerable) return false;
    }
    if (!d.isData() and !d.isAccessor()) return true;
    if (cur.is_accessor != d.isAccessor()) {
        if (!cur.configurable) return false;
    } else if (!cur.is_accessor) {
        if (!cur.configurable and !cur.writable) {
            if (d.has_writ and d.writ_val) return false;
            if (d.has_val and !sameValue(d.val, cur.value)) return false;
        }
    } else {
        if (!cur.configurable) {
            if (d.has_get and !sameValue(d.get_val, cur.value)) return false;
            if (d.has_set and !sameValue(d.set_val, cur.setter)) return false;
        }
    }
    return true;
}

fn defineOwnPropertyParsed(rt: *Runtime, target: Value, k: object.Key, d: ParsedDesc, throw_on_reject: bool) Error!bool {
    var root_buf = [_]Value{ target, d.val, d.get_val, d.set_val, keyToRootValue(k) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (target.isObject() and target.asObject().kind == .proxy) {
        const desc_obj = try parsedDescToObject(rt, d);
        const ok = try proxyDefineProperty(rt, target.asObject(), k, d, desc_obj);
        if (!ok and throw_on_reject) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned falsish" }});
        }
        return ok;
    }

    if (target.isObject() and target.asObject().kind == .array and k == .atom and object.isNamed(k, "length") and d.has_val) {
        const n = try ops.toNumber(rt, d.val);
        if (!(n >= 0 and n <= @as(f64, std.math.maxInt(u32)) and @floor(n) == n)) {
            return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
        }
    }

    const current = try getOwnPropertyRaw(rt, target, k);
    var next: heap_mod.Property = undefined;

    if (current == null) {
        const extensible = switch (target.unpack()) {
            .object => |o| o.extensible,
            .closure => |c| if (c.meta) |m| m.extensible else true,
            .native => true,
            else => false,
        };
        if (!extensible) {
            if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot define property, object is not extensible" }});
            return false;
        }
        next = d.toCompleteProperty();
    } else {
        const cur = current.?;
        if (!isCompatiblePropertyDescriptor(d, cur)) {
            if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot redefine property" }});
            return false;
        }
        if (!d.isData() and !d.isAccessor()) {
            next = cur;
        } else if (cur.is_accessor != d.isAccessor()) {
            if (d.isAccessor()) {
                next = .{
                    .is_accessor = true,
                    .value = if (d.has_get) d.get_val else .undefined,
                    .setter = if (d.has_set) d.set_val else .undefined,
                    .enumerable = cur.enumerable,
                    .configurable = cur.configurable,
                    .writable = false,
                };
            } else {
                next = .{
                    .is_accessor = false,
                    .value = if (d.has_val) d.val else .undefined,
                    .writable = if (d.has_writ) d.writ_val else false,
                    .enumerable = cur.enumerable,
                    .configurable = cur.configurable,
                };
            }
        } else if (!cur.is_accessor) {
            next = .{
                .is_accessor = false,
                .value = if (d.has_val) d.val else cur.value,
                .writable = if (d.has_writ) d.writ_val else cur.writable,
                .enumerable = if (d.has_enum) d.enum_val else cur.enumerable,
                .configurable = if (d.has_conf) d.conf_val else cur.configurable,
            };
        } else {
            next = .{
                .is_accessor = true,
                .value = if (d.has_get) d.get_val else cur.value,
                .setter = if (d.has_set) d.set_val else cur.setter,
                .enumerable = if (d.has_enum) d.enum_val else cur.enumerable,
                .configurable = if (d.has_conf) d.conf_val else cur.configurable,
                .writable = false,
            };
        }
        if (d.has_enum) next.enumerable = d.enum_val;
        if (d.has_conf) next.configurable = d.conf_val;
    }

    if (target.isObject() and target.asObject().kind == .array and k == .index) {
        const arr = target.asObject();
        const cur_len = arr.kind.array.items.len;
        if (k.index >= cur_len and !arr.array_length_writable) {
            if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot add property to array with non-writable length" }});
            return false;
        }
        if (k.index > cur_len) return rt.fail(.sparse_array);
        if (next.is_accessor or !next.enumerable or next.writable != arr.array_elements_writable or next.configurable != arr.array_elements_configurable) {
            return unsupportedReceiver(rt, "defineProperty");
        }
        if (k.index < cur_len) {
            if (d.has_val) rt.heap.storeElement(arr, k.index, next.value);
        } else {
            try rt.heap.appendElement(arr, next.value);
        }
        return true;
    }

    if (target.isObject() and target.asObject().kind == .array and k == .atom and object.isNamed(k, "length")) {
        if (d.has_val) {
            if (!try object.setWithReceiver(rt, target, k, next.value, target, throw_on_reject)) return false;
        }
        if (d.has_writ and !next.writable) target.asObject().array_length_writable = false;
        return true;
    }
    if (target.isObject() and target.asObject().kind == .regexp and object.isNamed(k, "lastIndex")) {
        if (d.has_val) {
            if (!target.asObject().regexp_last_index_writable and !sameValue(next.value, target.asObject().kind.regexp.last_index)) {
                if (throw_on_reject) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot redefine property" }});
                return false;
            }
            rt.heap.storeRegExpLastIndex(target.asObject(), next.value);
        }
        if (d.has_writ and !next.writable) target.asObject().regexp_last_index_writable = false;
        return true;
    }
    if (target.isClosure() and object.isNamed(k, "prototype") and hasAutoPrototype(target.asClosure())) {
        if (d.has_val) try rt.heap.storeClosurePrototype(@constCast(target.asClosure()), next.value);
        if (d.has_writ and !next.writable) (try rt.heap.ensureClosureMeta(@constCast(target.asClosure()))).prototype_writable = false;
        return true;
    }
    if (target.isClosure() and (object.isNamed(k, "name") or object.isNamed(k, "length"))) {
        const m = try rt.heap.ensureClosureMeta(@constCast(target.asClosure()));
        if (object.isNamed(k, "name")) {
            m.name_configurable = next.configurable;
            m.name_deleted = false;
        } else {
            m.length_configurable = next.configurable;
            m.length_deleted = false;
        }
        const pk = try object.propKey(rt, k);
        try rt.heap.defineClosurePropKey(@constCast(target.asClosure()), pk, next);
        return true;
    }
    if (target.isNative()) {
        const n = target.asNative();
        if (object.isNamed(k, "name") or object.isNamed(k, "length")) {
            const is_len = object.isNamed(k, "length");
            try rt.setNativePropDeleted(n, is_len, false);
            return true;
        }
        if (try namespaceObject(rt, n)) |ns| {
            const pk = try object.propKey(rt, k);
            try rt.heap.definePropKey(ns, pk, next);
            return true;
        }
        return rt.fail(.function_properties);
    }

    const pk = try object.propKey(rt, k);
    switch (target.unpack()) {
        .object => |o| try rt.heap.definePropKey(o, pk, next),
        .closure => |c| try rt.heap.defineClosurePropKey(@constCast(c), pk, next),
        else => unreachable,
    }
    return true;
}

fn defineOwnPropertyFromDesc(rt: *Runtime, target: Value, k: object.Key, desc: Value) Error!void {
    const parsed = try parsePropertyDescriptor(rt, desc);
    _ = try defineOwnPropertyParsed(rt, target, k, parsed, true);
}

pub fn ordinarySetWithReceiver(rt: *Runtime, receiver: Value, k: object.Key, v: Value, strict: bool) Error!bool {
    var root_buf = [_]Value{ receiver, v, keyToRootValue(k) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const existing = try getOwnPropertyRaw(rt, receiver, k);
    if (existing) |ex| {
        if (ex.is_accessor or !ex.writable) {
            if (strict) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot assign to read only property" }});
            return false;
        }
        return defineOwnPropertyParsed(rt, receiver, k, .{ .has_val = true, .val = v }, strict);
    }
    return defineOwnPropertyParsed(rt, receiver, k, .{
        .has_val = true,
        .val = v,
        .has_writ = true,
        .writ_val = true,
        .has_enum = true,
        .enum_val = true,
        .has_conf = true,
        .conf_val = true,
    }, strict);
}

fn objectDefineProperty(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (!target.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Object.defineProperty called on non-object" }});
    }
    const k = try object.key(rt, arg(args, 1));
    try defineOwnPropertyFromDesc(rt, target, k, arg(args, 2));
    return target;
}

fn objectDefineProperties(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (!target.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Object.defineProperties called on non-object" }});
    }
    const props = arg(args, 1);
    if (props.isUndefined() or props.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var root_buf = [_]Value{ target, props, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const keys: []object.Key = switch (props.unpack()) {
        .object => |o| try object.ownAllKeys(rt, o),
        .closure => |c| try object.ownAllKeysClosure(rt, c),
        .string => |s| blk: {
            if (s.units.len > 0) return rt.throw(.TypeError, &.{.{ .ascii = "Property description must be an object" }});
            break :blk &.{};
        },
        else => &.{},
    };
    defer rt.gpa.free(keys);
    if (keys.len > 0) {
        const key_vals = try rt.gpa.alloc(Value, keys.len);
        defer rt.gpa.free(key_vals);
        for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
        var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
        try key_roots.register(rt);
        defer key_roots.unregister(rt);

        for (keys) |k| {
            const desc = try object.get(rt, props, k);
            root_buf[2] = desc;
            try defineOwnPropertyFromDesc(rt, target, k, desc);
            root_buf[2] = .undefined;
        }
    }
    return target;
}

pub fn isArray(rt: *Runtime, v: Value) Error!bool {
    var cur = v;
    while (cur.isObject()) {
        if (cur.asObject().kind == .array or cur.asObject().builtin == .array_prototype) return true;
        if (cur.asObject().kind != .proxy) return false;
        try rt.checkNativeStack();
        cur = cur.asObject().kind.proxy.target orelse return rt.throw(.TypeError, &.{.{ .ascii = "Cannot perform 'IsArray' on a proxy that has been revoked" }});
    }
    return false;
}

fn arrayIsArray(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try isArray(rt, arg(args, 0)));
}

fn keyToString(rt: *Runtime, k: object.Key) Error!*heap_mod.String {
    return switch (k) {
        .atom => |a| a,
        .index => |i| blk: {
            var buf: [10]u8 = undefined;
            break :blk try rt.heap.ascii(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        },
        .symbol => unreachable,
    };
}

fn ownKeyValue(rt: *Runtime, o: *Object, k: object.Key) Error!Value {
    if (o.kind == .array and k == .index) return o.kind.array.items[k.index];
    return object.get(rt, Value.fromObject(o), k);
}

fn objectValuesEntriesImpl(rt: *Runtime, args: []const Value, comptime is_entries: bool) Error!Value {
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ arg(args, 0), Value.fromObject(out), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (arg(args, 0).unpack()) {
        .undefined, .null => return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }}),
        .boolean, .number, .bigint, .symbol, .native => {},
        .closure => |c| {
            const keys = try object.ownKeysClosure(rt, c);
            defer rt.gpa.free(keys);
            for (keys) |k| {
                const val = try object.get(rt, arg(args, 0), k);
                if (is_entries) {
                    const key_s = try keyToString(rt, k);
                    root_buf[2] = Value.fromString(key_s);
                    root_buf[3] = val;
                    const pair = try makePairArray(rt, root_buf[2], val);
                    root_buf[2] = pair;
                    try rt.heap.appendElement(out, pair);
                    root_buf[2] = .undefined;
                    root_buf[3] = .undefined;
                } else {
                    try rt.heap.appendElement(out, val);
                }
            }
        },
        .string => |s| for (0..s.units.len) |i| {
            const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }});
            root_buf[2] = Value.fromString(ch);
            if (is_entries) {
                const key_s = try keyToString(rt, .{ .index = @intCast(i) });
                root_buf[3] = Value.fromString(key_s);
                const pair = try makePairArray(rt, root_buf[3], root_buf[2]);
                root_buf[2] = pair;
                try rt.heap.appendElement(out, pair);
            } else {
                try rt.heap.appendElement(out, root_buf[2]);
            }
            root_buf[2] = .undefined;
            root_buf[3] = .undefined;
        },
        .object => |o| {
            const keys = try object.ownKeys(rt, o);
            defer rt.gpa.free(keys);
            for (keys) |k| {
                const val = try ownKeyValue(rt, o, k);
                if (is_entries) {
                    const key_s = try keyToString(rt, k);
                    root_buf[2] = Value.fromString(key_s);
                    root_buf[3] = val;
                    const pair = try makePairArray(rt, root_buf[2], val);
                    root_buf[2] = pair;
                    try rt.heap.appendElement(out, pair);
                    root_buf[2] = .undefined;
                    root_buf[3] = .undefined;
                } else {
                    try rt.heap.appendElement(out, val);
                }
            }
        },
    }
    return Value.fromObject(out);
}

fn objectValues(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return objectValuesEntriesImpl(rt, args, false);
}

fn objectEntries(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return objectValuesEntriesImpl(rt, args, true);
}

fn objectAssign(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target_in = arg(args, 0);
    if (target_in.isUndefined() or target_in.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    if (target_in.isNative()) return rt.fail(.function_properties);
    const target = if (target_in.isObjectLike()) target_in else try objectConstruct(rt, &.{target_in});
    if (args.len <= 1) return target;

    var root_buf = [_]Value{ target, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (args[1..]) |src| {
        root_buf[1] = src;
        switch (src.unpack()) {
            .undefined, .null, .boolean, .number, .bigint, .symbol, .native => {},
            .closure => |c| {
                const keys = try object.ownAllKeysClosure(rt, c);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const val = try object.get(rt, src, k);
                    root_buf[2] = val;
                    try object.setStrict(rt, target, k, val);
                    root_buf[2] = .undefined;
                }
            },
            .string => |s| for (0..s.units.len) |i| {
                const ch = try rt.heap.newString(&.{.{ .utf16 = s.units[i .. i + 1] }});
                root_buf[2] = Value.fromString(ch);
                try object.setStrict(rt, target, .{ .index = @intCast(i) }, root_buf[2]);
                root_buf[2] = .undefined;
            },
            .object => |src_obj| {
                const keys = try object.ownAllKeys(rt, src_obj);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const val = try ownKeyValue(rt, src_obj, k);
                    root_buf[2] = val;
                    try object.setStrict(rt, target, k, val);
                    root_buf[2] = .undefined;
                }
            },
        }
        root_buf[1] = .undefined;
    }
    return target;
}

fn setPrototypeOfValue(rt: *Runtime, target: Value, proto: Value) Error!bool {
    switch (proto.unpack()) {
        .object, .null => {},
        .native, .closure => return rt.fail(.function_properties),
        else => return rt.throw(.TypeError, &.{.{ .ascii = "Object prototype may only be an Object or null" }}),
    }
    switch (target.unpack()) {
        .object => |o| if (o.kind == .proxy) return proxySetPrototypeOf(rt, o, proto),
        .closure => {},
        .native => return rt.fail(.function_properties),
        else => return true,
    }
    const cur_proto = try object.getPrototypeOfValue(rt, target);
    if (sameValue(proto, cur_proto)) return true;

    const extensible = switch (target.unpack()) {
        .object => |o| o.extensible,
        .closure => |c| if (c.meta) |m| m.extensible else true,
        else => unreachable,
    };
    if (!extensible) return false;

    var p = proto;
    while (!p.isNull()) {
        if (sameValue(p, target)) return false;
        p = try object.getPrototypeOfValue(rt, p);
    }

    switch (target.unpack()) {
        .object => |o| rt.heap.storeObjectProto(o, if (proto.isNull()) null else proto.asObject()),
        .closure => |c| try rt.heap.storeClosureProto(@constCast(c), proto),
        else => unreachable,
    }
    return true;
}

fn objectSetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    const proto = arg(args, 1);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    if (!try setPrototypeOfValue(rt, target, proto)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Object.setPrototypeOf failed" }});
    }
    return target;
}

fn preventExtensionsValue(rt: *Runtime, target: Value) Error!bool {
    switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) return proxyPreventExtensions(rt, o);
            o.extensible = false;
        },
        .closure => |c| (try rt.heap.ensureClosureMeta(@constCast(c))).extensible = false,
        .native => return rt.fail(.function_properties),
        else => {},
    }
    return true;
}

fn objectPreventExtensions(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (!try preventExtensionsValue(rt, target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot prevent extensions" }});
    }
    return target;
}

fn isExtensibleValue(rt: *Runtime, target: Value) Error!bool {
    return switch (target.unpack()) {
        .object => |o| if (o.kind == .proxy) proxyIsExtensible(rt, o) else o.extensible,
        .closure => |c| if (c.meta) |m| m.extensible else true,
        .native => true,
        else => false,
    };
}

fn objectIsExtensible(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try isExtensibleValue(rt, arg(args, 0)));
}

fn setIntegrityLevel(rt: *Runtime, target: Value, freeze: bool) Error!Value {
    switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) {
                if (!try preventExtensionsValue(rt, target)) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot prevent extensions" }});
                }
                var root_buf = [_]Value{target};
                var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try roots.register(rt);
                defer roots.unregister(rt);

                const keys = try object.ownAllKeys(rt, o);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);

                for (keys) |k| {
                    const desc = try getOwnPropertyRaw(rt, target, k);
                    if (desc) |d| {
                        var pd: ParsedDesc = .{ .has_conf = true, .conf_val = false };
                        if (freeze and !d.is_accessor) {
                            pd.has_writ = true;
                            pd.writ_val = false;
                        }
                        _ = try defineOwnPropertyParsed(rt, target, k, pd, true);
                    }
                }
                return target;
            }
            o.extensible = false;
            if (o.props.count() > 0) {
                try rt.heap.toDictionary(o);
                for (o.props.dict.values()) |*p| {
                    p.configurable = false;
                    if (freeze and !p.is_accessor) p.writable = false;
                }
            }
            switch (o.kind) {
                .array => {
                    o.array_elements_configurable = false;
                    if (freeze) {
                        o.array_elements_writable = false;
                        o.array_length_writable = false;
                    }
                },
                .regexp => if (freeze) {
                    o.regexp_last_index_writable = false;
                },
                .typed_array => |ta| if (ta.length > 0) {
                    return rt.throw(.TypeError, &.{.{ .ascii = "Cannot freeze array buffer views with elements" }});
                },
                else => {},
            }
        },
        .closure => |c| {
            const m = try rt.heap.ensureClosureMeta(@constCast(c));
            m.extensible = false;
            m.name_configurable = false;
            m.length_configurable = false;
            if (freeze) m.prototype_writable = false;
            for (m.props.values()) |*p| {
                p.configurable = false;
                if (freeze and !p.is_accessor) p.writable = false;
            }
        },
        .native => return rt.fail(.function_properties),
        else => {},
    }
    return target;
}

fn testIntegrityLevel(_: *Runtime, target: Value, freeze: bool) Error!bool {
    return switch (target.unpack()) {
        .object => |o| {
            if (o.extensible) return false;
            var pit = o.props.iterator();
            while (pit.next()) |entry| {
                const p = entry.value_ptr.*;
                if (p.configurable) return false;
                if (freeze and !p.is_accessor and p.writable) return false;
            }
            switch (o.kind) {
                .array => |elements| {
                    if (elements.items.len > 0) {
                        if (o.array_elements_configurable) return false;
                        if (freeze and o.array_elements_writable) return false;
                    }
                    if (freeze and o.array_length_writable) return false;
                },
                .regexp => if (freeze and o.regexp_last_index_writable) return false,
                .typed_array => |ta| if (freeze and ta.length > 0) return false,
                else => {},
            }
            return true;
        },
        .closure => |c| {
            const m = c.meta orelse return false;
            if (m.extensible) return false;
            if (m.name_configurable or m.length_configurable) return false;
            if (freeze and hasAutoPrototype(c) and m.prototype_writable) return false;
            for (m.props.values()) |p| {
                if (p.configurable) return false;
                if (freeze and !p.is_accessor and p.writable) return false;
            }
            return true;
        },
        .native => return false,
        else => true,
    };
}

fn objectSeal(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return setIntegrityLevel(rt, arg(args, 0), false);
}

fn objectIsSealed(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try testIntegrityLevel(rt, arg(args, 0), false));
}

fn objectFreeze(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return setIntegrityLevel(rt, arg(args, 0), true);
}

fn objectIsFrozen(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(try testIntegrityLevel(rt, arg(args, 0), true));
}

fn objectHasOwn(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const k = try object.key(rt, arg(args, 1));
    return Value.fromBool(try object.hasOwn(rt, target, k));
}

fn objectIs(_: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(sameValue(arg(args, 0), arg(args, 1)));
}

fn objectGetOwnPropertyNames(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (target.isUndefined() or target.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ target, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (target.unpack()) {
        .object => |o| {
            const keys = try object.ownPropertyNames(rt, o);
            defer rt.gpa.free(keys);
            for (keys) |k| {
                const s = try keyToString(rt, k);
                try rt.heap.appendElement(out, Value.fromString(s));
            }
            if (o.kind == .array) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
            } else if (o.kind == .regexp) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("lastIndex")));
            }
        },
        .closure => |c| {
            if (!(c.meta != null and c.meta.?.length_deleted)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
            }
            if (!(c.meta != null and c.meta.?.name_deleted)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("name")));
            }
            if (hasAutoPrototype(c)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("prototype")));
            }
            const keys = try object.ownPropertyNamesClosure(rt, c);
            defer rt.gpa.free(keys);
            for (keys) |k| {
                if ((object.isNamed(k, "length") and !(c.meta != null and c.meta.?.length_deleted)) or
                    (object.isNamed(k, "name") and !(c.meta != null and c.meta.?.name_deleted))) continue;
                const s = try keyToString(rt, k);
                try rt.heap.appendElement(out, Value.fromString(s));
            }
        },
        .native => |n| {
            if (!rt.isNativePropDeleted(n, true)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
            }
            if (!rt.isNativePropDeleted(n, false)) {
                try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("name")));
            }
        },
        .string => |s| {
            for (0..s.units.len) |i| {
                try rt.heap.appendElement(out, Value.fromString(try keyToString(rt, .{ .index = @intCast(i) })));
            }
            try rt.heap.appendElement(out, Value.fromString(try rt.heap.ascii("length")));
        },
        else => {},
    }
    return Value.fromObject(out);
}

fn objectFromEntries(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const iterable = arg(args, 0);
    const r = try realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    const iter = try getIterator(rt, iterable);
    var root_buf = [_]Value{ Value.fromObject(out), Value.fromObject(iter), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    while (try iteratorNextVal(rt, iter)) |item| {
        root_buf[2] = item;
        if (!item.isObject() and !item.isClosure() and !item.isNative()) {
            try iteratorClose(rt, iter, false);
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator value is not an entry object" }});
        }
        const k_val = object.get(rt, item, .{ .index = 0 }) catch |e| {
            iteratorClose(rt, iter, true) catch {};
            return e;
        };
        root_buf[3] = k_val;
        const v_val = object.get(rt, item, .{ .index = 1 }) catch |e| {
            iteratorClose(rt, iter, true) catch {};
            return e;
        };
        const k = object.key(rt, k_val) catch |e| {
            iteratorClose(rt, iter, true) catch {};
            return e;
        };
        try object.definePublicField(rt, Value.fromObject(out), k, v_val);
        root_buf[2] = .undefined;
        root_buf[3] = .undefined;
    }
    return Value.fromObject(out);
}

fn objectGroupBy(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const iterable = arg(args, 0);
    const cb = try requireCallable(rt, arg(args, 1));
    var root_buf = [_]Value{ iterable, cb, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);
    const r = try realm(rt);
    const out = try rt.heap.newObject(null);
    root_buf[0] = Value.fromObject(out);

    var idx: usize = 0;
    while (try iteratorNextVal(rt, iter)) |item| : (idx += 1) {
        root_buf[3] = item;
        const raw_key = rt.callCallable(cb, .undefined, &.{ item, Value.fromNumber(@floatFromInt(idx)) }) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = raw_key;
        const k = object.key(rt, raw_key) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        const group_arr: *Object = blk: {
            if (try object.ownProp(rt, out, k)) |p| {
                break :blk p.value.asObject();
            }
            const arr = try rt.heap.newArray(r.array_prototype);
            root_buf[5] = Value.fromObject(arr);
            try object.definePublicField(rt, Value.fromObject(out), k, Value.fromObject(arr));
            break :blk arr;
        };
        try rt.heap.appendElement(group_arr, item);
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
    }
    return Value.fromObject(out);
}

fn objectProtoHasOwnProperty(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const k = try object.key(rt, arg(args, 0));
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    return Value.fromBool(try object.hasOwn(rt, this, k));
}

fn objectProtoIsPrototypeOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject() and !v.isClosure() and !v.isNative()) return Value.fromBool(false);
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var cur = try object.getPrototypeOfValue(rt, v);
    while (!cur.isNull()) {
        if (sameValue(cur, this)) return Value.fromBool(true);
        cur = try object.getPrototypeOfValue(rt, cur);
    }
    return Value.fromBool(false);
}

fn objectProtoPropertyIsEnumerable(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const k = try object.key(rt, arg(args, 0));
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const desc = (try getOwnPropertyRaw(rt, this, k)) orelse return Value.fromBool(false);
    return Value.fromBool(desc.enumerable);
}

/// Builds a `for...in` iterator over `target`'s own and inherited enumerable string keys (D69).
pub fn forInInit(rt: *Runtime, target: Value) Error!*Object {
    const keys_arr = try rt.heap.newArray(null);
    var root_buf = [_]Value{ target, Value.fromObject(keys_arr) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    switch (target.unpack()) {
        .undefined, .null, .boolean, .number, .bigint, .symbol => return rt.heap.newForInIterator(target, keys_arr),
        .string => |s| {
            for (0..s.units.len) |i| {
                try rt.heap.appendElement(keys_arr, Value.fromString(try keyToString(rt, .{ .index = @intCast(i) })));
            }
            return rt.heap.newForInIterator(target, keys_arr);
        },
        .object, .closure, .native => {},
    }

    var seen: std.AutoHashMapUnmanaged(*heap_mod.String, void) = .empty;
    defer seen.deinit(rt.gpa);

    var cur: Value = target;
    var cur_root = [_]Value{cur};
    var cur_roots: rt_mod.ValueRoots = .{ .values = &cur_root };
    try cur_roots.register(rt);
    defer cur_roots.unregister(rt);

    while (!cur.isNull()) {
        cur_root[0] = cur;
        switch (cur.unpack()) {
            .object => |o| {
                const keys = try object.ownPropertyNames(rt, o);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const atom = try object.atomOf(rt, k);
                    const gop = try seen.getOrPut(rt.gpa, atom);
                    if (gop.found_existing) continue;
                    const desc = (try getOwnPropertyRaw(rt, cur, k)) orelse continue;
                    if (desc.enumerable) {
                        try rt.heap.appendElement(keys_arr, Value.fromString(atom));
                    }
                }
            },
            .closure => |c| {
                const keys = try object.ownPropertyNamesClosure(rt, c);
                defer rt.gpa.free(keys);
                const key_vals = try rt.gpa.alloc(Value, keys.len);
                defer rt.gpa.free(key_vals);
                for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
                var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
                try key_roots.register(rt);
                defer key_roots.unregister(rt);
                for (keys) |k| {
                    const atom = try object.atomOf(rt, k);
                    const gop = try seen.getOrPut(rt.gpa, atom);
                    if (gop.found_existing) continue;
                    const desc = (try getOwnPropertyRaw(rt, cur, k)) orelse continue;
                    if (desc.enumerable) {
                        try rt.heap.appendElement(keys_arr, Value.fromString(atom));
                    }
                }
            },
            else => {},
        }
        cur = try object.getPrototypeOfValue(rt, cur);
    }

    return rt.heap.newForInIterator(target, keys_arr);
}

/// Returns the next still-present enumerable key for a `for...in` iterator, or `null` when done (D69).
pub fn forInNext(rt: *Runtime, iter: *Object) Error!?Value {
    var root_buf = [_]Value{ Value.fromObject(iter), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const it = &iter.kind.iterator;
    while (it.cursor < it.next_method.asObject().kind.array.items.len) {
        const key_str = it.next_method.asObject().kind.array.items[it.cursor].asString();
        it.cursor += 1;
        if (it.target.isString()) return Value.fromString(key_str);
        const k: object.Key = if (key_str.atom.?.index) |idx| .{ .index = idx } else .{ .atom = @constCast(key_str) };
        var cur: Value = it.target;
        while (!cur.isNull()) {
            root_buf[1] = cur;
            if (try getOwnPropertyRaw(rt, cur, k)) |desc| {
                if (desc.enumerable) return Value.fromString(key_str);
                break; // shadowed by non-enumerable property
            }
            cur = try object.getPrototypeOfValue(rt, cur);
        }
    }
    return null;
}

fn arrayOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    if (!this.isNative() or this.asNative() != &array_global) {
        if (isConstructor(this)) {
            const len_val: Value = Value.fromNumber(@floatFromInt(args.len));
            const a = try constructWithNewTarget(rt, this, &.{len_val}, this);
            var root_buf = [_]Value{a};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            for (args, 0..) |v, i| {
                _ = try defineOwnPropertyParsed(rt, a, .{ .index = @intCast(i) }, .{
                    .has_val = true,
                    .val = v,
                    .has_writ = true,
                    .writ_val = true,
                    .has_enum = true,
                    .enum_val = true,
                    .has_conf = true,
                    .conf_val = true,
                }, true);
            }
            _ = try object.setWithReceiver(rt, a, try object.named(rt, "length"), len_val, a, true);
            return a;
        }
    }
    const out = try rt.heap.newArray(r.array_prototype);
    try rt.heap.appendElements(out, args);
    return Value.fromObject(out);
}

fn arrayFrom(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const items = arg(args, 0);
    const has_map = args.len >= 2 and !args[1].isUndefined();
    const map_fn: Value = if (has_map) try requireCallable(rt, args[1]) else .undefined;
    const this_arg = arg(args, 2);

    const r = try realm(rt);
    var root_buf = [_]Value{ this, items, map_fn, this_arg, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (items.isUndefined() or items.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }

    const custom_ctor = isConstructor(this) and !(this.isNative() and this.asNative() == &array_global);

    if (try object.getMethod(rt, items, .{ .symbol = r.sym_iterator })) |iter_fn| {
        const out_val: Value = if (custom_ctor)
            try constructValue(rt, this, &.{})
        else
            Value.fromObject(try rt.heap.newArray(r.array_prototype));
        root_buf[4] = out_val;

        const iter = try getIteratorWithMethod(rt, items, iter_fn);
        root_buf[5] = Value.fromObject(iter);

        var k: usize = 0;
        while (try iteratorNextVal(rt, iter)) |elem| : (k += 1) {
            root_buf[6] = elem;
            const val = if (has_map)
                rt.callCallable(map_fn, this_arg, &.{ root_buf[6], Value.fromNumber(@floatFromInt(k)) }) catch |e| {
                    if (e == error.Thrown) try iteratorClose(rt, iter, true);
                    return e;
                }
            else
                elem;
            root_buf[6] = val;
            arrayAppendOrDefine(rt, out_val, k, val) catch |e| {
                if (e == error.Thrown) try iteratorClose(rt, iter, true);
                return e;
            };
            root_buf[6] = .undefined;
        }
        if (custom_ctor) {
            try object.setStrict(rt, out_val, try object.named(rt, "length"), Value.fromNumber(@floatFromInt(k)));
        }
        return out_val;
    }

    const len_f = try toLength(rt, try object.get(rt, items, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const out_val: Value = if (custom_ctor)
        try constructValue(rt, this, &.{Value.fromNumber(len_f)})
    else
        Value.fromObject(try rt.heap.newArray(r.array_prototype));
    root_buf[4] = out_val;

    for (0..len) |k| {
        const elem = try object.get(rt, items, .{ .index = @intCast(k) });
        root_buf[6] = elem;
        const val = if (has_map)
            try rt.callCallable(map_fn, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(k)) })
        else
            elem;
        root_buf[6] = val;
        try arrayAppendOrDefine(rt, out_val, k, val);
        root_buf[6] = .undefined;
    }
    if (custom_ctor) {
        try object.setStrict(rt, out_val, try object.named(rt, "length"), Value.fromNumber(len_f));
    }
    return out_val;
}

fn arrayFromAsync(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    const res_p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(res_p) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    arrayFromAsyncStart(rt, this, args, res_p) catch |e| {
        if (e == error.Thrown) {
            const reason = try rt.catchValue();
            try settlePromiseFromJob(rt, res_p, true, reason);
            return Value.fromObject(res_p);
        }
        return e;
    };
    return Value.fromObject(res_p);
}

fn arrayFromAsyncStart(rt: *Runtime, this: Value, args: []const Value, res_p: *Object) Error!void {
    const items = arg(args, 0);
    const mapfn = arg(args, 1);
    const this_arg = arg(args, 2);
    if (!mapfn.isUndefined() and !mapfn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Array.fromAsync: mapfn is not callable" }});
    }
    if (items.isUndefined() or items.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }

    const r = try realm(rt);
    const env = try rt.heap.newArray(null);
    var root_buf = [_]Value{ this, items, mapfn, this_arg, Value.fromObject(res_p), Value.fromObject(env), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var iter_val: Value = .undefined;
    var next_method: Value = .undefined;
    var is_async_iter = false;
    var limit_val: Value = .undefined;

    if (try object.getMethod(rt, items, .{ .symbol = r.sym_async_iterator })) |async_fn| {
        const iter = try getIteratorWithMethod(rt, items, async_fn);
        iter_val = Value.fromObject(iter);
        root_buf[6] = iter_val;
        next_method = try object.get(rt, iter_val, try object.named(rt, "next"));
        root_buf[7] = next_method;
        is_async_iter = true;
    } else if (try object.getMethod(rt, items, .{ .symbol = r.sym_iterator })) |sync_fn| {
        const iter = try getIteratorWithMethod(rt, items, sync_fn);
        iter_val = Value.fromObject(iter);
        root_buf[6] = iter_val;
        next_method = try object.get(rt, iter_val, try object.named(rt, "next"));
        root_buf[7] = next_method;
        is_async_iter = false;
    } else {
        iter_val = items;
        const len_f = try toLength(rt, try object.get(rt, items, try object.named(rt, "length")));
        limit_val = Value.fromNumber(len_f);
    }

    const custom_ctor = isConstructor(this) and !(this.isNative() and this.asNative() == &array_global);
    const out_val: Value = if (custom_ctor)
        (if (next_method.isUndefined()) try constructValue(rt, this, &.{limit_val}) else try constructValue(rt, this, &.{}))
    else
        Value.fromObject(try rt.heap.newArray(r.array_prototype));
    root_buf[8] = out_val;

    // env layout: [0]=res_p, [1]=out, [2]=mapfn, [3]=this_arg, [4]=source/iter, [5]=next_method, [6]=index, [7]=limit, [8]=is_async_iter, [9]=custom_ctor
    try rt.heap.appendElements(env, &.{
        Value.fromObject(res_p),
        out_val,
        mapfn,
        this_arg,
        iter_val,
        next_method,
        Value.fromNumber(0),
        limit_val,
        Value.fromBool(is_async_iter),
        Value.fromBool(custom_ctor),
    });
    try arrayFromAsyncStep(rt, env);
}

fn arrayFromAsyncCloseOnErr(rt: *Runtime, env: *Object, reason: Value) Error!void {
    const res_p = env.kind.array.items[0].asObject();
    const next_method = env.kind.array.items[5];
    if (!next_method.isUndefined()) {
        const iter = env.kind.array.items[4];
        if (iter.isObject()) {
            const is_async = env.kind.array.items[8].asBool();
            if (!is_async) {
                iteratorClose(rt, iter.asObject(), true) catch {};
            } else {
                const ret_m = object.getMethod(rt, iter, try object.named(rt, "return")) catch null;
                if (ret_m) |rm| {
                    _ = rt.callCallable(rm, iter, &.{}) catch {};
                }
            }
        }
    }
    try settlePromiseFromJob(rt, res_p, true, reason);
}

fn arrayFromAsyncStep(rt: *Runtime, env: *Object) Error!void {
    var root_buf = [_]Value{ Value.fromObject(env), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const res_p = env.kind.array.items[0].asObject();
    const source = env.kind.array.items[4];
    const next_method = env.kind.array.items[5];
    const is_async = env.kind.array.items[8].asBool();

    if (!next_method.isUndefined()) {
        const next_res = rt.callCallable(next_method, source, &.{}) catch |e| {
            if (e == error.Thrown) {
                try settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[1] = next_res;
        if (is_async) {
            const p = resolveToPromise(rt, next_res) catch |e| {
                if (e == error.Thrown) {
                    try settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
                    return;
                }
                return e;
            };
            root_buf[1] = p;
            const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncIterNextCb, env);
            root_buf[2] = Value.fromClosure(on_ful);
            const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncRejectCb, env);
            root_buf[3] = Value.fromClosure(on_rej);
            _ = try promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
            return;
        }
        try arrayFromAsyncProcessIterResult(rt, env, next_res, false);
        return;
    }

    const k_f = env.kind.array.items[6].asNumber();
    const lim_f = env.kind.array.items[7].asNumber();
    if (k_f >= lim_f) {
        try arrayFromAsyncFinish(rt, env);
        return;
    }
    const key: object.Key = if (k_f <= @as(f64, @floatFromInt(std.math.maxInt(u32))))
        .{ .index = @intFromFloat(k_f) }
    else
        try object.key(rt, Value.fromNumber(k_f));
    const elem = object.get(rt, source, key) catch |e| {
        if (e == error.Thrown) {
            try settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = elem;
    const p = resolveToPromise(rt, elem) catch |e| {
        if (e == error.Thrown) {
            try settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = p;
    const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncMapAndStoreCb, env);
    root_buf[2] = Value.fromClosure(on_ful);
    const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncRejectCb, env);
    root_buf[3] = Value.fromClosure(on_rej);
    _ = try promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
}

fn arrayFromAsyncProcessIterResult(rt: *Runtime, env: *Object, next_res: Value, is_async: bool) Error!void {
    var root_buf = [_]Value{ Value.fromObject(env), next_res, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const res_p = env.kind.array.items[0].asObject();
    if (!next_res.isObject()) {
        const err_v = try makeEngineError(rt, .TypeError, try rt.heap.ascii("Iterator result is not an object"));
        try settlePromiseFromJob(rt, res_p, true, err_v);
        return;
    }
    const done_v = object.get(rt, next_res, try object.named(rt, "done")) catch |e| {
        if (e == error.Thrown) {
            try settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    if (ops.toBoolean(done_v)) {
        try arrayFromAsyncFinish(rt, env);
        return;
    }
    const val = object.get(rt, next_res, try object.named(rt, "value")) catch |e| {
        if (e == error.Thrown) {
            try settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = val;
    if (is_async) {
        try arrayFromAsyncApplyMapOrStore(rt, env, val);
        return;
    }
    // Sync iterator: await the yielded value before mapping/storing.
    const p = resolveToPromise(rt, val) catch |e| {
        if (e == error.Thrown) {
            try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
            return;
        }
        return e;
    };
    root_buf[1] = p;
    const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncMapAndStoreCb, env);
    root_buf[2] = Value.fromClosure(on_ful);
    const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncCloseRejectCb, env);
    root_buf[3] = Value.fromClosure(on_rej);
    _ = try promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
}

fn arrayFromAsyncIterNextCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncProcessIterResult(rt, env, arg(args, 0), true);
    return .undefined;
}

fn arrayFromAsyncRejectCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    const res_p = env.kind.array.items[0].asObject();
    try settlePromiseFromJob(rt, res_p, true, arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncCloseRejectCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncCloseOnErr(rt, env, arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncApplyMapOrStore(rt: *Runtime, env: *Object, val: Value) Error!void {
    var root_buf = [_]Value{ Value.fromObject(env), val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const mapfn = env.kind.array.items[2];
    const this_arg = env.kind.array.items[3];
    const k_val = env.kind.array.items[6];
    if (!mapfn.isUndefined()) {
        const mapped = rt.callCallable(mapfn, this_arg, &.{ val, k_val }) catch |e| {
            if (e == error.Thrown) {
                try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[1] = mapped;
        const p = resolveToPromise(rt, mapped) catch |e| {
            if (e == error.Thrown) {
                try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[1] = p;
        const on_ful = try rt.heap.newNativeClosure(&arrayFromAsyncStoreCb, env);
        root_buf[2] = Value.fromClosure(on_ful);
        const on_rej = try rt.heap.newNativeClosure(&arrayFromAsyncCloseRejectCb, env);
        root_buf[3] = Value.fromClosure(on_rej);
        _ = try promiseThen(rt, p, &.{ root_buf[2], root_buf[3] });
        return;
    }
    try arrayFromAsyncStoreAndAdvance(rt, env, val);
}

fn arrayFromAsyncMapAndStoreCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncApplyMapOrStore(rt, env, arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncStoreCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    try arrayFromAsyncStoreAndAdvance(rt, env, arg(args, 0));
    return .undefined;
}

fn arrayFromAsyncFinish(rt: *Runtime, env: *Object) Error!void {
    const res_p = env.kind.array.items[0].asObject();
    const out = env.kind.array.items[1];
    if (env.kind.array.items[9].asBool()) {
        object.setStrict(rt, out, try object.named(rt, "length"), env.kind.array.items[6]) catch |e| {
            if (e == error.Thrown) {
                try settlePromiseFromJob(rt, res_p, true, try rt.catchValue());
                return;
            }
            return e;
        };
    }
    try settlePromiseFromJob(rt, res_p, false, out);
}

fn arrayFromAsyncStoreAndAdvance(rt: *Runtime, env: *Object, val: Value) Error!void {
    const out = env.kind.array.items[1];
    const k_f = env.kind.array.items[6].asNumber();
    const k: usize = @intFromFloat(k_f);
    arrayAppendOrDefine(rt, out, k, val) catch |e| {
        if (e == error.Thrown) {
            try arrayFromAsyncCloseOnErr(rt, env, try rt.catchValue());
            return;
        }
        return e;
    };
    rt.heap.storeElement(env, 6, Value.fromNumber(k_f + 1.0));
    try arrayFromAsyncStep(rt, env);
}

fn stringCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return Value.fromString(try rt.heap.newString(&.{}));
    if (args[0].isSymbol()) return Value.fromString(try symbolDescriptiveString(rt, args[0].asSymbol()));
    return Value.fromString(try toStringObj(rt, args[0]));
}

fn stringConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const s = if (args.len == 0) try rt.heap.newString(&.{}) else try toStringObj(rt, args[0]);
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const r = try realm(rt);
    return Value.fromObject(try rt.heap.newPrimitiveWrapper(r.string_prototype, root_buf[0]));
}

const string_to_string: Native = .{ .name = "toString", .length = 0, .call = stringToString };
const string_value_of: Native = .{ .name = "valueOf", .length = 0, .call = stringValueOf };

fn thisStringExact(rt: *Runtime, this: Value) Error!*const heap_mod.String {
    if (this.isString()) return this.asString();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isString()) return o.kind.primitive_wrapper.asString();
        if (o.builtin == .string_prototype) return rt.heap.newString(&.{});
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype method requires a String receiver" }});
}

fn stringToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromString(try thisStringExact(rt, this));
}

fn stringValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromString(try thisStringExact(rt, this));
}

fn objectCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return objectConstruct(rt, args);
}

fn objectConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const v = arg(args, 0);
    const r = try realm(rt);
    return switch (v.unpack()) {
        .undefined, .null => Value.fromObject(try rt.heap.newObject(r.object_prototype)),
        .object, .closure, .native => v,
        .boolean => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.boolean_prototype, v)),
        .number => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.number_prototype, v)),
        .string => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.string_prototype, v)),
        .symbol => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.symbol_prototype, v)),
        .bigint => Value.fromObject(try rt.heap.newPrimitiveWrapper(r.bigint_prototype, v)),
    };
}

fn arrayCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return arrayConstruct(rt, args);
}

fn arrayConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    if (args.len == 0) {
        return Value.fromObject(try rt.heap.newArray(r.array_prototype));
    }
    if (args.len == 1) {
        const first = args[0];
        if (first.isNumber()) {
            const n = first.asNumber();
            const int_len = ops.toUint32(n);
            if (@as(f64, @floatFromInt(int_len)) != n) {
                return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array length" }});
            }
            if (int_len > 0) return rt.fail(.sparse_array);
            return Value.fromObject(try rt.heap.newArray(r.array_prototype));
        }
        const out = try rt.heap.newArray(r.array_prototype);
        try rt.heap.appendElement(out, first);
        return Value.fromObject(out);
    }
    const out = try rt.heap.newArray(r.array_prototype);
    try rt.heap.appendElements(out, args);
    return Value.fromObject(out);
}

const boolean_to_string: Native = .{ .name = "toString", .length = 0, .call = booleanToString };
const boolean_value_of: Native = .{ .name = "valueOf", .length = 0, .call = booleanValueOf };

fn booleanCall(_: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(ops.toBoolean(arg(args, 0)));
}

fn booleanConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const b = Value.fromBool(ops.toBoolean(arg(args, 0)));
    const r = try realm(rt);
    return Value.fromObject(try rt.heap.newPrimitiveWrapper(r.boolean_prototype, b));
}

fn thisBoolean(rt: *Runtime, this: Value) Error!bool {
    if (this.isBool()) return this.asBool();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isBool()) return o.kind.primitive_wrapper.asBool();
        if (o.builtin == .boolean_prototype) return false;
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Boolean.prototype method requires a Boolean receiver" }});
}

fn booleanToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const b = try thisBoolean(rt, this);
    return Value.fromString(try rt.heap.ascii(if (b) "true" else "false"));
}

fn booleanValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromBool(try thisBoolean(rt, this));
}

// ---------------------------------------------------------------- Symbol (M36, D66)

const symbol_for: Native = .{ .name = "for", .length = 1, .call = symbolFor };
const symbol_key_for: Native = .{ .name = "keyFor", .length = 1, .call = symbolKeyFor };
const symbol_to_string: Native = .{ .name = "toString", .call = symbolToString };
const symbol_value_of: Native = .{ .name = "valueOf", .call = symbolValueOf };
const symbol_description_getter: Native = .{ .name = "get description", .call = symbolDescriptionGetter };

fn symbolDescriptiveString(rt: *Runtime, sym: *const heap_mod.Symbol) Error!*const heap_mod.String {
    return if (sym.description) |d|
        rt.heap.newString(&.{ .{ .ascii = "Symbol(" }, .{ .utf16 = d.units }, .{ .ascii = ")" } })
    else
        rt.heap.ascii("Symbol()");
}

fn symbolCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const desc: ?*const heap_mod.String = if (args.len == 0 or args[0].isUndefined())
        null
    else
        try toStringObj(rt, args[0]);
    return Value.fromSymbol(try rt.heap.newSymbol(desc, false));
}

fn symbolFor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const key_str = try toStringObj(rt, arg(args, 0));
    if (rt.global_symbols.get(key_str)) |sym| {
        return Value.fromSymbol(sym);
    }
    var root_buf = [_]Value{Value.fromString(key_str)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const sym = try rt.heap.newSymbol(key_str, true);
    try rt.global_symbols.putNoClobber(rt.gpa, key_str, sym);
    return Value.fromSymbol(sym);
}

fn symbolKeyFor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isSymbol()) return rt.throw(.TypeError, &.{.{ .ascii = "Symbol.keyFor requires a symbol argument" }});
    const sym = v.asSymbol();
    return if (sym.is_global) Value.fromString(sym.description.?) else .undefined;
}

fn thisSymbol(rt: *Runtime, this: Value, name: []const u8) Error!*const heap_mod.Symbol {
    return switch (this.unpack()) {
        .symbol => |s| s,
        .object => |o| if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isSymbol())
            o.kind.primitive_wrapper.asSymbol()
        else
            rt.throw(.TypeError, &.{ .{ .ascii = "Symbol.prototype." }, .{ .ascii = name }, .{ .ascii = " requires that 'this' be a Symbol" } }),
        else => rt.throw(.TypeError, &.{ .{ .ascii = "Symbol.prototype." }, .{ .ascii = name }, .{ .ascii = " requires that 'this' be a Symbol" } }),
    };
}

fn symbolToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const sym = try thisSymbol(rt, this, "toString");
    return Value.fromString(try symbolDescriptiveString(rt, sym));
}

fn symbolValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromSymbol(try thisSymbol(rt, this, "valueOf"));
}

fn symbolDescriptionGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const sym = try thisSymbol(rt, this, "description");
    return if (sym.description) |d| Value.fromString(d) else .undefined;
}

fn numberCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    if (args.len == 0) return Value.fromNumber(0);
    const prim = if (args[0].isObjectLike()) try object.toPrimitive(rt, args[0], .number) else args[0];
    if (prim.isBigInt()) return Value.fromNumber(bigint.toF64(prim.asBigInt()));
    return Value.fromNumber(try ops.toNumber(rt, prim));
}

fn numberConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const n_val = try numberCall(rt, .undefined, args);
    const r = try realm(rt);
    return Value.fromObject(try rt.heap.newPrimitiveWrapper(r.number_prototype, n_val));
}

fn bigintCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const v_in = arg(args, 0);
    const prim = if (v_in.isObjectLike()) try object.toPrimitive(rt, v_in, .number) else v_in;
    return switch (prim.unpack()) {
        .bigint => prim,
        .number => |n| Value.fromBigInt(try bigint.fromF64Exact(rt, n)),
        .boolean => |b| Value.fromBigInt(try bigint.fromU64(rt, if (b) 1 else 0)),
        .string => |s| Value.fromBigInt((try ops.stringToBigIntOpt(rt, s.units)) orelse
            return rt.throw(.SyntaxError, &.{.{ .ascii = "Cannot convert string to a BigInt" }})),
        .undefined, .null, .symbol => rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert value to a BigInt" }}),
        .native, .closure, .object => unreachable,
    };
}

fn toBigIntWidth(rt: *Runtime, v: Value) Error!u64 {
    const n = try ops.toNumber(rt, v);
    if (std.math.isNan(n) or n == 0.0) return 0;
    const t = @trunc(n);
    if (!std.math.isFinite(t) or t < 0.0 or t > 9007199254740991.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid BigInt bit width" }});
    }
    return @intFromFloat(t);
}

fn bigintAsIntN(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const bits = try toBigIntWidth(rt, arg(args, 0));
    const b = try ops.toBigInt(rt, arg(args, 1));
    return Value.fromBigInt(try bigint.asIntN(rt, bits, b));
}

fn bigintAsUintN(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const bits = try toBigIntWidth(rt, arg(args, 0));
    const b = try ops.toBigInt(rt, arg(args, 1));
    return Value.fromBigInt(try bigint.asUintN(rt, bits, b));
}

fn thisBigInt(rt: *Runtime, this: Value) Error!*const heap_mod.BigInt {
    if (this.isBigInt()) return this.asBigInt();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isBigInt()) return o.kind.primitive_wrapper.asBigInt();
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "BigInt.prototype method called on non-BigInt" }});
}

fn bigintToString(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const b = try thisBigInt(rt, this);
    var radix: u8 = 10;
    if (args.len > 0 and !args[0].isUndefined()) {
        const r_num = try toIntegerOrInfinity(rt, args[0]);
        if (r_num < 2.0 or r_num > 36.0) {
            return rt.throw(.RangeError, &.{.{ .ascii = "toString() radix argument must be between 2 and 36" }});
        }
        radix = @intFromFloat(r_num);
    }
    const s = try bigint.toString(rt, b, radix);
    defer rt.gpa.free(s);
    return Value.fromString(try rt.heap.ascii(s));
}

fn bigintValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromBigInt(try thisBigInt(rt, this));
}

const bigint_as_int_n: Native = .{ .name = "asIntN", .length = 2, .call = bigintAsIntN };
const bigint_as_uint_n: Native = .{ .name = "asUintN", .length = 2, .call = bigintAsUintN };
const bigint_to_string: Native = .{ .name = "toString", .length = 0, .call = bigintToString };
const bigint_value_of: Native = .{ .name = "valueOf", .length = 0, .call = bigintValueOf };

const number_to_string: Native = .{ .name = "toString", .length = 0, .call = numberToString };
const number_to_fixed: Native = .{ .name = "toFixed", .length = 1, .call = numberToFixed };
const number_to_exponential: Native = .{ .name = "toExponential", .length = 1, .call = numberToExponential };
const number_to_precision: Native = .{ .name = "toPrecision", .length = 1, .call = numberToPrecision };
const number_to_locale_string: Native = .{ .name = "toLocaleString", .length = 0, .call = numberToLocaleString };
const number_value_of: Native = .{ .name = "valueOf", .length = 0, .call = numberValueOf };

fn thisNumber(rt: *Runtime, this: Value) Error!f64 {
    if (this.isNumber()) return this.asNumber();
    if (this.isObject()) {
        const o = this.asObject();
        if (o.kind == .primitive_wrapper and o.kind.primitive_wrapper.isNumber()) return o.kind.primitive_wrapper.asNumber();
        if (o.builtin == .number_prototype) return 0.0;
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Number.prototype method requires a Number receiver" }});
}

fn numberValueOf(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return Value.fromNumber(try thisNumber(rt, this));
}

fn numberToString(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const n = try thisNumber(rt, this);
    if (args.len > 0 and !args[0].isUndefined()) {
        const r_num = try toIntegerOrInfinity(rt, args[0]);
        if (r_num < 2.0 or r_num > 36.0) {
            return rt.throw(.RangeError, &.{.{ .ascii = "toString() radix argument must be between 2 and 36" }});
        }
        const radix: u8 = @intFromFloat(r_num);
        if (radix != 10) {
            if (std.math.isNan(n)) return Value.fromString(try rt.heap.ascii("NaN"));
            if (n == 0.0) return Value.fromString(try rt.heap.ascii("0"));
            if (!std.math.isFinite(n)) return Value.fromString(try rt.heap.ascii(if (n < 0) "-Infinity" else "Infinity"));
            if (@trunc(n) == n and @abs(n) <= 9007199254740991.0) {
                const neg = n < 0;
                const abs_i: u64 = @intFromFloat(@abs(n));
                var out_buf: [70]u8 = undefined;
                var idx: usize = out_buf.len;
                var v = abs_i;
                const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
                while (v > 0) {
                    idx -= 1;
                    out_buf[idx] = digits[v % radix];
                    v /= radix;
                }
                if (neg) {
                    idx -= 1;
                    out_buf[idx] = '-';
                }
                return Value.fromString(try rt.heap.ascii(out_buf[idx..]));
            }
        }
    }
    return Value.fromString(try toStringObj(rt, Value.fromNumber(n)));
}

fn numberToLocaleString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const n = try thisNumber(rt, this);
    return Value.fromString(try toStringObj(rt, Value.fromNumber(n)));
}

fn formatJsExp(out: []u8, raw: []const u8) []const u8 {
    // Normalize Zig scientific output `...eN` -> `...e+N` (JS always emits an explicit sign).
    const e_pos = std.mem.indexOfScalar(u8, raw, 'e') orelse {
        @memcpy(out[0..raw.len], raw);
        return out[0..raw.len];
    };
    @memcpy(out[0 .. e_pos + 1], raw[0 .. e_pos + 1]);
    const pos: usize = e_pos + 1;
    if (pos < raw.len and raw[pos] != '+' and raw[pos] != '-') {
        out[pos] = '+';
        @memcpy(out[pos + 1 .. pos + 1 + (raw.len - pos)], raw[pos..]);
        return out[0 .. raw.len + 1];
    }
    @memcpy(out[pos..raw.len], raw[pos..]);
    return out[0..raw.len];
}

fn numberToFixed(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const x_raw = try thisNumber(rt, this);
    const f_f = try toIntegerOrInfinity(rt, arg(args, 0));
    if (!std.math.isFinite(f_f) or f_f < 0.0 or f_f > 100.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "toFixed() digits argument must be between 0 and 100" }});
    }
    if (!std.math.isFinite(x_raw) or @abs(x_raw) >= 1e21) {
        return Value.fromString(try toStringObj(rt, Value.fromNumber(x_raw)));
    }
    const x = if (x_raw == 0.0) 0.0 else x_raw;
    const f: usize = @intFromFloat(f_f);
    var buf: [512]u8 = undefined;
    const rendered = std.fmt.float.render(&buf, x, .{ .mode = .decimal, .precision = f }) catch unreachable;
    return Value.fromString(try rt.heap.ascii(rendered));
}

fn numberToExponential(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const x_raw = try thisNumber(rt, this);
    const f_arg = arg(args, 0);
    const f_f = try toIntegerOrInfinity(rt, f_arg);
    if (!std.math.isFinite(x_raw)) {
        return Value.fromString(try toStringObj(rt, Value.fromNumber(x_raw)));
    }
    if (!f_arg.isUndefined() and (f_f < 0.0 or f_f > 100.0)) {
        return rt.throw(.RangeError, &.{.{ .ascii = "toExponential() argument must be between 0 and 100" }});
    }
    const x = if (x_raw == 0.0) 0.0 else x_raw;
    const prec: ?usize = if (f_arg.isUndefined()) null else @intFromFloat(f_f);
    var raw_buf: [512]u8 = undefined;
    const raw = std.fmt.float.render(&raw_buf, x, .{ .mode = .scientific, .precision = prec }) catch unreachable;
    var out_buf: [512]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(formatJsExp(&out_buf, raw)));
}

fn numberToPrecision(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const x_raw = try thisNumber(rt, this);
    const p_arg = arg(args, 0);
    if (p_arg.isUndefined()) {
        return Value.fromString(try toStringObj(rt, Value.fromNumber(x_raw)));
    }
    const p_f = try toIntegerOrInfinity(rt, p_arg);
    if (!std.math.isFinite(x_raw)) {
        return Value.fromString(try toStringObj(rt, Value.fromNumber(x_raw)));
    }
    if (p_f < 1.0 or p_f > 100.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "toPrecision() argument must be between 1 and 100" }});
    }
    const p: usize = @intFromFloat(p_f);
    const neg = x_raw < 0.0;
    const ax = if (x_raw == 0.0) 0.0 else @abs(x_raw);

    var raw_buf: [512]u8 = undefined;
    const raw = std.fmt.float.render(&raw_buf, ax, .{ .mode = .scientific, .precision = p - 1 }) catch unreachable;
    const e_pos = std.mem.indexOfScalar(u8, raw, 'e') orelse unreachable;
    const exp = std.fmt.parseInt(i32, raw[e_pos + 1 ..], 10) catch unreachable;

    // Extract the p significant digits (skipping any '.').
    var digits: [128]u8 = undefined;
    var dlen: usize = 0;
    for (raw[0..e_pos]) |ch| {
        if (ch != '.') {
            digits[dlen] = ch;
            dlen += 1;
        }
    }
    while (dlen < p) : (dlen += 1) digits[dlen] = '0';

    var out: [512]u8 = undefined;
    var oi: usize = 0;
    if (neg) {
        out[oi] = '-';
        oi += 1;
    }
    if (exp < -6 or exp >= @as(i32, @intCast(p))) {
        out[oi] = digits[0];
        oi += 1;
        if (p > 1) {
            out[oi] = '.';
            oi += 1;
            @memcpy(out[oi..][0 .. p - 1], digits[1..p]);
            oi += p - 1;
        }
        out[oi] = 'e';
        oi += 1;
        if (exp >= 0) {
            out[oi] = '+';
            oi += 1;
            const es = std.fmt.bufPrint(out[oi..], "{d}", .{exp}) catch unreachable;
            oi += es.len;
        } else {
            const es = std.fmt.bufPrint(out[oi..], "{d}", .{exp}) catch unreachable;
            oi += es.len;
        }
    } else if (exp == @as(i32, @intCast(p)) - 1) {
        @memcpy(out[oi..][0..p], digits[0..p]);
        oi += p;
    } else if (exp >= 0) {
        const int_digits: usize = @intCast(exp + 1);
        @memcpy(out[oi..][0..int_digits], digits[0..int_digits]);
        oi += int_digits;
        out[oi] = '.';
        oi += 1;
        @memcpy(out[oi..][0 .. p - int_digits], digits[int_digits..p]);
        oi += p - int_digits;
    } else {
        out[oi] = '0';
        out[oi + 1] = '.';
        oi += 2;
        const zeros: usize = @intCast(-exp - 1);
        @memset(out[oi..][0..zeros], '0');
        oi += zeros;
        @memcpy(out[oi..][0..p], digits[0..p]);
        oi += p;
    }
    return Value.fromString(try rt.heap.ascii(out[0..oi]));
}

fn numberIsNaN(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isNan(v.asNumber()));
}

fn numberIsFinite(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isFinite(v.asNumber()));
}

fn numberIsInteger(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isNumber()) return Value.fromBool(false);
    const n = v.asNumber();
    return Value.fromBool(std.math.isFinite(n) and @trunc(n) == n);
}

fn numberIsSafeInteger(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isNumber()) return Value.fromBool(false);
    const n = v.asNumber();
    return Value.fromBool(std.math.isFinite(n) and @trunc(n) == n and @abs(n) <= 9007199254740991.0);
}

fn globalIsNaN(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(std.math.isNan(try ops.toNumber(rt, arg(args, 0))));
}

fn globalIsFinite(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromBool(std.math.isFinite(try ops.toNumber(rt, arg(args, 0))));
}

fn isUriUnescaped(u: u16, keep_reserved: bool) bool {
    if (u >= 128) return false;
    const c: u8 = @intCast(u);
    switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '!', '~', '*', '\'', '(', ')' => return true,
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => return keep_reserved,
        else => return false,
    }
}

fn isUriReserved(b: u8) bool {
    return switch (b) {
        ';', '/', '?', ':', '@', '&', '=', '+', '$', ',', '#' => true,
        else => false,
    };
}

fn uriHexVal(u: u16) ?u8 {
    return switch (u) {
        '0'...'9' => @intCast(u - '0'),
        'a'...'f' => @intCast(u - 'a' + 10),
        'A'...'F' => @intCast(u - 'A' + 10),
        else => null,
    };
}

fn throwURIError(rt: *Runtime) Error {
    const r = try realm(rt);
    const err_obj = try buildError(rt, r.uri_error_prototype, Value.fromString(try rt.heap.ascii("URI malformed")), .undefined);
    return rt.throwValue(Value.fromObject(err_obj));
}

fn encodeUriImpl(rt: *Runtime, args: []const Value, keep_reserved: bool) Error!Value {
    const s = try toStringObj(rt, arg(args, 0));
    const units = s.units;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    const hex = "0123456789ABCDEF";
    var k: usize = 0;
    while (k < units.len) {
        const c = units[k];
        if (isUriUnescaped(c, keep_reserved)) {
            if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try out.append(rt.gpa, c);
            k += 1;
            continue;
        }
        if (c >= 0xDC00 and c <= 0xDFFF) {
            return throwURIError(rt);
        }
        var cp: u21 = c;
        if (c >= 0xD800 and c <= 0xDBFF) {
            if (k + 1 >= units.len) return throwURIError(rt);
            const c2 = units[k + 1];
            if (c2 < 0xDC00 or c2 > 0xDFFF) return throwURIError(rt);
            cp = 0x10000 + ((@as(u21, c - 0xD800) << 10) | @as(u21, c2 - 0xDC00));
            k += 2;
        } else {
            k += 1;
        }
        var utf8_buf: [4]u8 = undefined;
        const n: usize = std.unicode.utf8Encode(cp, &utf8_buf) catch unreachable;
        if (out.items.len + n * 3 > rt.limits.max_string_length) return rt.limit(.string_length);
        try out.ensureUnusedCapacity(rt.gpa, n * 3);
        for (utf8_buf[0..n]) |b| {
            out.appendAssumeCapacity('%');
            out.appendAssumeCapacity(hex[b >> 4]);
            out.appendAssumeCapacity(hex[b & 0xF]);
        }
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn decodeUriImpl(rt: *Runtime, args: []const Value, keep_reserved: bool) Error!Value {
    const s = try toStringObj(rt, arg(args, 0));
    const units = s.units;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    var k: usize = 0;
    while (k < units.len) {
        const c = units[k];
        if (c != '%') {
            if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try out.append(rt.gpa, c);
            k += 1;
            continue;
        }
        const start = k;
        if (k + 2 >= units.len) return throwURIError(rt);
        const h1 = uriHexVal(units[k + 1]) orelse return throwURIError(rt);
        const h2 = uriHexVal(units[k + 2]) orelse return throwURIError(rt);
        const b0 = (h1 << 4) | h2;
        k += 3;
        if (b0 < 0x80) {
            if (keep_reserved and isUriReserved(b0)) {
                if (out.items.len + 3 > rt.limits.max_string_length) return rt.limit(.string_length);
                try out.appendSlice(rt.gpa, units[start .. start + 3]);
            } else {
                if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
                try out.append(rt.gpa, b0);
            }
            continue;
        }
        const n: usize = switch (b0) {
            0xC2...0xDF => 2,
            0xE0...0xEF => 3,
            0xF0...0xF4 => 4,
            else => return throwURIError(rt),
        };
        var octets: [4]u8 = undefined;
        octets[0] = b0;
        for (1..n) |j| {
            if (k + 2 >= units.len or units[k] != '%') {
                return throwURIError(rt);
            }
            const ch1 = uriHexVal(units[k + 1]) orelse return throwURIError(rt);
            const ch2 = uriHexVal(units[k + 2]) orelse return throwURIError(rt);
            const bj = (ch1 << 4) | ch2;
            if (bj < 0x80 or bj > 0xBF) return throwURIError(rt);
            octets[j] = bj;
            k += 3;
        }
        const cp = std.unicode.utf8Decode(octets[0..n]) catch return throwURIError(rt);
        if (cp < 0x10000) {
            if (out.items.len >= rt.limits.max_string_length) return rt.limit(.string_length);
            try out.append(rt.gpa, @intCast(cp));
        } else {
            if (out.items.len + 2 > rt.limits.max_string_length) return rt.limit(.string_length);
            const v = cp - 0x10000;
            try out.append(rt.gpa, @intCast(0xD800 + (v >> 10)));
            try out.append(rt.gpa, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn globalEncodeURI(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return encodeUriImpl(rt, args, true);
}

fn globalDecodeURI(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return decodeUriImpl(rt, args, true);
}

fn globalEncodeURIComponent(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return encodeUriImpl(rt, args, false);
}

fn globalDecodeURIComponent(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return decodeUriImpl(rt, args, false);
}

fn parseFloatImpl(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const s = try toStringObj(rt, arg(args, 0));
    var units = s.units;
    var start: usize = 0;
    while (start < units.len and isJsWhitespace(units[start])) start += 1;
    units = units[start..];
    if (units.len == 0) return Value.fromNumber(std.math.nan(f64));

    var negative = false;
    var i: usize = 0;
    if (units[0] == '-') {
        negative = true;
        i = 1;
    } else if (units[0] == '+') {
        i = 1;
    }
    const body = units[i..];
    const inf_lit = "Infinity";
    if (body.len >= inf_lit.len) {
        var is_inf = true;
        for (inf_lit, 0..) |c, j| {
            if (body[j] != c) {
                is_inf = false;
                break;
            }
        }
        if (is_inf) return Value.fromNumber(if (negative) -std.math.inf(f64) else std.math.inf(f64));
    }

    var p: usize = 0;
    var digits: usize = 0;
    while (p < body.len and body[p] >= '0' and body[p] <= '9') : (p += 1) digits += 1;
    if (p < body.len and body[p] == '.') {
        p += 1;
        while (p < body.len and body[p] >= '0' and body[p] <= '9') : (p += 1) digits += 1;
    }
    if (digits == 0) return Value.fromNumber(std.math.nan(f64));

    if (p < body.len and (body[p] == 'e' or body[p] == 'E')) {
        var ep = p + 1;
        if (ep < body.len and (body[ep] == '+' or body[ep] == '-')) ep += 1;
        const exp_digits_start = ep;
        while (ep < body.len and body[ep] >= '0' and body[ep] <= '9') ep += 1;
        if (ep > exp_digits_start) p = ep;
    }

    var stack_buf: [128]u8 = undefined;
    const heap_buf: []u8 = if (p > stack_buf.len) try rt.gpa.alloc(u8, p) else &.{};
    defer if (heap_buf.len > 0) rt.gpa.free(heap_buf);
    const ascii_buf = if (p > stack_buf.len) heap_buf else stack_buf[0..p];
    for (body[0..p], ascii_buf) |u, *c| c.* = @intCast(u);

    const v = std.fmt.parseFloat(f64, ascii_buf) catch unreachable;
    return Value.fromNumber(if (negative) -v else v);
}

fn digitVal(c: u8, radix: u8) ?u8 {
    const v: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => return null,
    };
    return if (v < radix) v else null;
}

fn parseIntImpl(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const s = try toStringObj(rt, arg(args, 0));
    var root_buf = [_]Value{Value.fromString(s)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var r: i32 = @bitCast(ops.toUint32(try ops.toNumber(rt, arg(args, 1))));
    var units = s.units;
    var start: usize = 0;
    while (start < units.len and isJsWhitespace(units[start])) start += 1;
    units = units[start..];

    var negative = false;
    if (units.len > 0) {
        if (units[0] == '-') {
            negative = true;
            units = units[1..];
        } else if (units[0] == '+') {
            units = units[1..];
        }
    }

    var strip_prefix = true;
    if (r != 0) {
        if (r < 2 or r > 36) return Value.fromNumber(std.math.nan(f64));
        if (r != 16) strip_prefix = false;
    } else {
        r = 10;
    }

    if (strip_prefix and units.len >= 2 and units[0] == '0' and (units[1] == 'x' or units[1] == 'X')) {
        units = units[2..];
        r = 16;
    }

    const radix: u8 = @intCast(r);
    const radix_f: f64 = @floatFromInt(radix);
    var count: usize = 0;
    var acc: f64 = 0;
    for (units) |u| {
        if (u > 0x7F) break;
        const d = digitVal(@intCast(u), radix) orelse break;
        acc = acc * radix_f + @as(f64, @floatFromInt(d));
        count += 1;
    }
    if (count == 0) return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(if (negative) -acc else acc);
}

// ---------------------------------------------------------------- Math (M11.3)

fn registerMath(rt: *Runtime, m: *Object) Error!void {
    try immutableConstant(rt, m, "E", Value.fromNumber(std.math.e));
    try immutableConstant(rt, m, "LN2", Value.fromNumber(std.math.ln2));
    try immutableConstant(rt, m, "LN10", Value.fromNumber(std.math.ln10));
    try immutableConstant(rt, m, "LOG2E", Value.fromNumber(std.math.log2e));
    try immutableConstant(rt, m, "LOG10E", Value.fromNumber(std.math.log10e));
    try immutableConstant(rt, m, "PI", Value.fromNumber(std.math.pi));
    try immutableConstant(rt, m, "SQRT1_2", Value.fromNumber(std.math.sqrt1_2));
    try immutableConstant(rt, m, "SQRT2", Value.fromNumber(std.math.sqrt2));

    try method(rt, m, "abs", &math_abs);
    try method(rt, m, "floor", &math_floor);
    try method(rt, m, "ceil", &math_ceil);
    try method(rt, m, "round", &math_round);
    try method(rt, m, "trunc", &math_trunc);
    try method(rt, m, "min", &math_min);
    try method(rt, m, "max", &math_max);
    try method(rt, m, "pow", &math_pow);
    try method(rt, m, "sqrt", &math_sqrt);
    try method(rt, m, "sin", &math_sin);
    try method(rt, m, "cos", &math_cos);
    try method(rt, m, "tan", &math_tan);
    try method(rt, m, "asin", &math_asin);
    try method(rt, m, "acos", &math_acos);
    try method(rt, m, "atan", &math_atan);
    try method(rt, m, "atan2", &math_atan2);
    try method(rt, m, "log", &math_log);
    try method(rt, m, "exp", &math_exp);
    try method(rt, m, "sign", &math_sign);
    try method(rt, m, "clz32", &math_clz32);
    try method(rt, m, "imul", &math_imul);
    try method(rt, m, "fround", &math_fround);
    try method(rt, m, "hypot", &math_hypot);
    try method(rt, m, "random", &math_random);
}

const math_abs: Native = .{ .name = "abs", .call = mathAbs };
const math_floor: Native = .{ .name = "floor", .call = mathFloor };
const math_ceil: Native = .{ .name = "ceil", .call = mathCeil };
const math_round: Native = .{ .name = "round", .call = mathRound };
const math_trunc: Native = .{ .name = "trunc", .call = mathTrunc };
const math_min: Native = .{ .name = "min", .length = 2, .call = mathMin };
const math_max: Native = .{ .name = "max", .length = 2, .call = mathMax };
const math_pow: Native = .{ .name = "pow", .call = mathPow };
const math_sqrt: Native = .{ .name = "sqrt", .call = mathSqrt };
const math_sin: Native = .{ .name = "sin", .call = mathSin };
const math_cos: Native = .{ .name = "cos", .call = mathCos };
const math_tan: Native = .{ .name = "tan", .call = mathTan };
const math_asin: Native = .{ .name = "asin", .call = mathAsin };
const math_acos: Native = .{ .name = "acos", .call = mathAcos };
const math_atan: Native = .{ .name = "atan", .call = mathAtan };
const math_atan2: Native = .{ .name = "atan2", .call = mathAtan2 };
const math_log: Native = .{ .name = "log", .call = mathLog };
const math_exp: Native = .{ .name = "exp", .call = mathExp };
const math_sign: Native = .{ .name = "sign", .call = mathSign };
const math_clz32: Native = .{ .name = "clz32", .call = mathClz32 };
const math_imul: Native = .{ .name = "imul", .call = mathImul };
const math_fround: Native = .{ .name = "fround", .call = mathFround };
const math_hypot: Native = .{ .name = "hypot", .call = mathHypot };
const math_random: Native = .{ .name = "random", .call = mathRandom };

fn mathAbs(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@abs(try ops.toNumber(rt, arg(args, 0))));
}

fn mathFloor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@floor(try ops.toNumber(rt, arg(args, 0))));
}

fn mathCeil(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@ceil(try ops.toNumber(rt, arg(args, 0))));
}

fn mathTrunc(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@trunc(try ops.toNumber(rt, arg(args, 0))));
}

fn mathRound(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return Value.fromNumber(x);
    if (x >= -0.5 and x < 0.0) return Value.fromNumber(-0.0);
    if (@abs(x) >= 4503599627370496.0) return Value.fromNumber(x);
    const f = @floor(x);
    return Value.fromNumber(if (x - f >= 0.5) f + 1.0 else f);
}

fn mathMin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var best = std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isNan(v)) {
            saw_nan = true;
        } else if (!saw_nan) {
            if (v < best or (v == 0.0 and best == 0.0 and std.math.signbit(v))) best = v;
        }
    }
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else best);
}

fn mathMax(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var best = -std.math.inf(f64);
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isNan(v)) {
            saw_nan = true;
        } else if (!saw_nan) {
            if (v > best or (v == 0.0 and best == 0.0 and !std.math.signbit(v))) best = v;
        }
    }
    return Value.fromNumber(if (saw_nan) std.math.nan(f64) else best);
}

fn mathPow(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const base = try ops.toNumber(rt, arg(args, 0));
    const exp = try ops.toNumber(rt, arg(args, 1));
    return Value.fromNumber(ops.pow(base, exp));
}

fn mathSqrt(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.sqrt(try ops.toNumber(rt, arg(args, 0))));
}

fn mathSin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.sin(try ops.toNumber(rt, arg(args, 0))));
}

fn mathCos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.cos(try ops.toNumber(rt, arg(args, 0))));
}

fn mathTan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.tan(try ops.toNumber(rt, arg(args, 0))));
}

fn mathAsin(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.asin(try ops.toNumber(rt, arg(args, 0))));
}

fn mathAcos(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.acos(try ops.toNumber(rt, arg(args, 0))));
}

fn mathAtan(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(std.math.atan(try ops.toNumber(rt, arg(args, 0))));
}

fn mathAtan2(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const y = try ops.toNumber(rt, arg(args, 0));
    const x = try ops.toNumber(rt, arg(args, 1));
    return Value.fromNumber(std.math.atan2(y, x));
}

fn mathLog(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@log(try ops.toNumber(rt, arg(args, 0))));
}

fn mathExp(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(@exp(try ops.toNumber(rt, arg(args, 0))));
}

fn mathSign(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (std.math.isNan(x) or x == 0.0) return Value.fromNumber(x);
    return Value.fromNumber(if (x > 0.0) 1.0 else -1.0);
}

fn mathClz32(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const u = ops.toUint32(try ops.toNumber(rt, arg(args, 0)));
    return Value.fromNumber(@floatFromInt(@clz(u)));
}

fn mathImul(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const a: i32 = @bitCast(ops.toUint32(try ops.toNumber(rt, arg(args, 0))));
    const b: i32 = @bitCast(ops.toUint32(try ops.toNumber(rt, arg(args, 1))));
    return Value.fromNumber(@floatFromInt(a *% b));
}

fn mathFround(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const x = try ops.toNumber(rt, arg(args, 0));
    if (!std.math.isFinite(x) or x == 0.0) return Value.fromNumber(x);
    return Value.fromNumber(@as(f64, @floatCast(@as(f32, @floatCast(x)))));
}

fn mathHypot(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    var max_abs: f64 = 0.0;
    var saw_inf = false;
    var saw_nan = false;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        if (std.math.isInf(v)) {
            saw_inf = true;
        } else if (std.math.isNan(v)) {
            saw_nan = true;
        } else {
            const av = @abs(v);
            if (av > max_abs) max_abs = av;
        }
    }
    if (saw_inf) return Value.fromNumber(std.math.inf(f64));
    if (saw_nan) return Value.fromNumber(std.math.nan(f64));
    if (max_abs == 0.0) return Value.fromNumber(0.0);
    var sum: f64 = 0.0;
    for (args) |a| {
        const v = try ops.toNumber(rt, a);
        const s = v / max_abs;
        sum += s * s;
    }
    return Value.fromNumber(max_abs * std.math.sqrt(sum));
}

fn mathRandom(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromNumber(rt.nextRandom());
}

// ---------------------------------------------------------------- Map

const map_get: Native = .{ .name = "get", .call = mapGet };
const map_set: Native = .{ .name = "set", .call = mapSet };
const map_has: Native = .{ .name = "has", .call = mapHas };
const map_delete: Native = .{ .name = "delete", .call = mapDelete };
const map_clear: Native = .{ .name = "clear", .call = mapClear };
const map_keys: Native = .{ .name = "keys", .call = mapKeys };
const map_values: Native = .{ .name = "values", .call = mapValues };
const map_entries: Native = .{ .name = "entries", .call = mapEntries };
const map_for_each: Native = .{ .name = "forEach", .call = mapForEach };
const map_group_by: Native = .{ .name = "groupBy", .length = 2, .call = mapGroupBy };

fn mapWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Map requires 'new'" }});
}

fn mapConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    const m = try rt.heap.newMap(r.map_prototype);
    const iterable = arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(m);

    var root_buf = [_]Value{ iterable, Value.fromObject(m), .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try object.get(rt, Value.fromObject(m), try object.named(rt, "set"));
    if (!adder.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Map.prototype.set is not a function" }});
    root_buf[6] = adder;

    const iter = try getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);

    while (try iteratorNextVal(rt, iter)) |entry| {
        root_buf[3] = entry;
        if (!entry.isObjectLike()) {
            try iteratorClose(rt, iter, true);
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator value is not an entry object" }});
        }
        const k = object.get(rt, entry, .{ .index = 0 }) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = k;
        const v = object.get(rt, entry, .{ .index = 1 }) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[5] = v;
        if (adder.isNative() and adder.asNative() == &map_set) {
            try rt.heap.mapSet(m, k, v);
        } else {
            _ = rt.callCallable(adder, Value.fromObject(m), &.{ k, v }) catch |e| {
                if (e == error.Thrown) try iteratorClose(rt, iter, true);
                return e;
            };
        }
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
    }
    return Value.fromObject(m);
}

fn thisMap(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .map) return this.asObject();
    return unsupportedReceiver(rt, name);
}

fn mapGet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "get");
    return heap_mod.Heap.mapGet(m, arg(args, 0)) orelse .undefined;
}

fn mapSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "set");
    try rt.heap.mapSet(m, arg(args, 0), arg(args, 1));
    return this;
}

fn mapHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "has");
    return Value.fromBool(heap_mod.Heap.mapHas(m, arg(args, 0)));
}

fn mapDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "delete");
    return Value.fromBool(heap_mod.Heap.mapDelete(m, arg(args, 0)));
}

fn mapClear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const m = try thisMap(rt, this, "clear");
    heap_mod.Heap.mapClear(m);
    return .undefined;
}

fn mapKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "keys");
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .map_keys));
}

fn mapValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "values");
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .map_values));
}

fn mapEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisMap(rt, this, "entries");
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .map_entries));
}

fn mapForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const m = try thisMap(rt, this, "forEach");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ this, cb, this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    while (i < m.kind.map.entries.items.len) : (i += 1) {
        const e = m.kind.map.entries.items[i];
        if (!e.alive) continue;
        root_buf[3] = e.key;
        root_buf[4] = e.value;
        _ = try rt.callCallable(cb, this_arg, &.{ e.value, e.key, this });
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
    }
    return .undefined;
}

fn mapGroupBy(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const iterable = arg(args, 0);
    const cb = try requireCallable(rt, arg(args, 1));
    var root_buf = [_]Value{ iterable, cb, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);
    const r = try realm(rt);
    const out = try rt.heap.newMap(r.map_prototype);
    root_buf[0] = Value.fromObject(out);

    var idx: usize = 0;
    while (try iteratorNextVal(rt, iter)) |item| : (idx += 1) {
        root_buf[3] = item;
        const raw_key = rt.callCallable(cb, .undefined, &.{ item, Value.fromNumber(@floatFromInt(idx)) }) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        const key = if (raw_key.isNumber() and raw_key.asNumber() == 0.0) Value.fromNumber(0.0) else raw_key;
        root_buf[4] = key;
        const group_arr: *Object = blk: {
            if (heap_mod.Heap.mapGet(out, key)) |existing| {
                break :blk existing.asObject();
            }
            const arr = try rt.heap.newArray(r.array_prototype);
            root_buf[5] = Value.fromObject(arr);
            try rt.heap.mapSet(out, key, Value.fromObject(arr));
            break :blk arr;
        };
        try rt.heap.appendElement(group_arr, item);
        root_buf[3] = .undefined;
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
    }
    return Value.fromObject(out);
}

// ---------------------------------------------------------------- Set

const set_add: Native = .{ .name = "add", .call = setAdd };
const set_has: Native = .{ .name = "has", .call = setHas };
const set_delete: Native = .{ .name = "delete", .call = setDelete };
const set_clear: Native = .{ .name = "clear", .call = setClear };
const set_values: Native = .{ .name = "values", .call = setValues };
const set_entries: Native = .{ .name = "entries", .call = setEntries };
const set_for_each: Native = .{ .name = "forEach", .call = setForEach };
const set_union: Native = .{ .name = "union", .length = 1, .call = setUnion };
const set_intersection: Native = .{ .name = "intersection", .length = 1, .call = setIntersection };
const set_difference: Native = .{ .name = "difference", .length = 1, .call = setDifference };
const set_symmetric_difference: Native = .{ .name = "symmetricDifference", .length = 1, .call = setSymmetricDifference };
const set_is_subset_of: Native = .{ .name = "isSubsetOf", .length = 1, .call = setIsSubsetOf };
const set_is_superset_of: Native = .{ .name = "isSupersetOf", .length = 1, .call = setIsSupersetOf };
const set_is_disjoint_from: Native = .{ .name = "isDisjointFrom", .length = 1, .call = setIsDisjointFrom };

fn setWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Set requires 'new'" }});
}

fn setConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    const s = try rt.heap.newSet(r.set_prototype);
    const iterable = arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(s);

    var root_buf = [_]Value{ iterable, Value.fromObject(s), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try object.get(rt, Value.fromObject(s), try object.named(rt, "add"));
    if (!adder.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Set.prototype.add is not a function" }});
    root_buf[4] = adder;

    const iter = try getIterator(rt, iterable);
    root_buf[2] = Value.fromObject(iter);
    while (try iteratorNextVal(rt, iter)) |v| {
        root_buf[3] = v;
        if (adder.isNative() and adder.asNative() == &set_add) {
            try rt.heap.setAdd(s, v);
        } else {
            _ = rt.callCallable(adder, Value.fromObject(s), &.{v}) catch |e| {
                if (e == error.Thrown) try iteratorClose(rt, iter, true);
                return e;
            };
        }
        root_buf[3] = .undefined;
    }
    return Value.fromObject(s);
}

fn thisSet(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .set) return this.asObject();
    return unsupportedReceiver(rt, name);
}

fn setAdd(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "add");
    try rt.heap.setAdd(s, arg(args, 0));
    return this;
}

fn setHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "has");
    return Value.fromBool(heap_mod.Heap.setHas(s, arg(args, 0)));
}

fn setDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "delete");
    return Value.fromBool(heap_mod.Heap.setDelete(s, arg(args, 0)));
}

fn setClear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisSet(rt, this, "clear");
    heap_mod.Heap.setClear(s);
    return .undefined;
}

fn setValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisSet(rt, this, "values");
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .set_values));
}

fn setEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try thisSet(rt, this, "entries");
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .set_entries));
}

fn setForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "forEach");
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ this, cb, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    while (i < s.kind.set.entries.items.len) : (i += 1) {
        const e = s.kind.set.entries.items[i];
        if (!e.alive) continue;
        root_buf[3] = e.key;
        _ = try rt.callCallable(cb, this_arg, &.{ e.key, e.key, this });
        root_buf[3] = .undefined;
    }
    return .undefined;
}

const SetRecord = struct {
    obj: Value,
    size: f64,
    has: Value,
    keys: Value,
};

fn getSetRecord(rt: *Runtime, obj: Value) Error!SetRecord {
    if (!obj.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Argument must be an object" }});
    }
    var root_buf = [_]Value{ obj, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const raw_size = try object.get(rt, obj, try object.named(rt, "size"));
    const num_size = try ops.toNumber(rt, raw_size);
    if (std.math.isNan(num_size)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like size must not be NaN" }});
    }
    const int_size = if (num_size == 0) 0 else @trunc(num_size);
    if (int_size < 0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Set-like size must not be negative" }});
    }
    const has = try object.get(rt, obj, try object.named(rt, "has"));
    if (!has.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like object must have a callable 'has' method" }});
    }
    root_buf[1] = has;
    const keys = try object.get(rt, obj, try object.named(rt, "keys"));
    if (!keys.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like object must have a callable 'keys' method" }});
    }
    return .{ .obj = obj, .size = int_size, .has = has, .keys = keys };
}

fn getSetKeysIterator(rt: *Runtime, rec: SetRecord) Error!*Object {
    const r = try realm(rt);
    const iter_val = try rt.callCallable(rec.keys, rec.obj, &.{});
    if (!iter_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like keys() must return an object" }});
    }
    var root_buf = [_]Value{iter_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    if (!next_fn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Set-like keys iterator must have a callable 'next' method" }});
    }
    return rt.heap.newCustomIterator(r.iterator_prototype, iter_val, next_fn);
}

fn cloneSet(rt: *Runtime, s: *Object) Error!*Object {
    const r = try realm(rt);
    const out = try rt.heap.newSet(r.set_prototype);
    var root_buf = [_]Value{ Value.fromObject(s), Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (s.kind.set.entries.items) |e| {
        if (!e.alive) continue;
        try rt.heap.setAdd(out, e.key);
    }
    return out;
}

fn setUnion(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "union");
    const rec = try getSetRecord(rt, arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try cloneSet(rt, s);
    root_buf[4] = Value.fromObject(out);
    const iter = try getSetKeysIterator(rt, rec);
    root_buf[5] = Value.fromObject(iter);
    while (try iteratorNextVal(rt, iter)) |v| {
        root_buf[6] = v;
        try rt.heap.setAdd(out, v);
        root_buf[6] = .undefined;
    }
    return Value.fromObject(out);
}

fn setIntersection(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "intersection");
    const rec = try getSetRecord(rt, arg(args, 0));
    const r = try realm(rt);
    const out = try rt.heap.newSet(r.set_prototype);
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, Value.fromObject(out), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (@as(f64, @floatFromInt(s.kind.set.live_count)) <= rec.size) {
        var i: usize = 0;
        while (i < s.kind.set.entries.items.len) : (i += 1) {
            const e = s.kind.set.entries.items[i];
            if (!e.alive) continue;
            root_buf[6] = e.key;
            const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
            if (ops.toBoolean(res)) {
                try rt.heap.setAdd(out, root_buf[6]);
            }
            root_buf[6] = .undefined;
        }
    } else {
        const iter = try getSetKeysIterator(rt, rec);
        root_buf[5] = Value.fromObject(iter);
        while (try iteratorNextVal(rt, iter)) |v| {
            root_buf[6] = v;
            if (heap_mod.Heap.setHas(s, v)) {
                try rt.heap.setAdd(out, v);
            }
            root_buf[6] = .undefined;
        }
    }
    return Value.fromObject(out);
}

fn setDifference(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "difference");
    const rec = try getSetRecord(rt, arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try cloneSet(rt, s);
    root_buf[4] = Value.fromObject(out);
    if (@as(f64, @floatFromInt(s.kind.set.live_count)) <= rec.size) {
        var i: usize = 0;
        while (i < s.kind.set.entries.items.len) : (i += 1) {
            const e = s.kind.set.entries.items[i];
            if (!e.alive) continue;
            root_buf[6] = e.key;
            const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
            if (ops.toBoolean(res)) {
                _ = heap_mod.Heap.setDelete(out, root_buf[6]);
            }
            root_buf[6] = .undefined;
        }
    } else {
        const iter = try getSetKeysIterator(rt, rec);
        root_buf[5] = Value.fromObject(iter);
        while (try iteratorNextVal(rt, iter)) |v| {
            root_buf[6] = v;
            _ = heap_mod.Heap.setDelete(out, v);
            root_buf[6] = .undefined;
        }
    }
    return Value.fromObject(out);
}

fn setSymmetricDifference(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "symmetricDifference");
    const rec = try getSetRecord(rt, arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const out = try cloneSet(rt, s);
    root_buf[4] = Value.fromObject(out);
    const iter = try getSetKeysIterator(rt, rec);
    root_buf[5] = Value.fromObject(iter);
    while (try iteratorNextVal(rt, iter)) |v| {
        root_buf[6] = v;
        if (heap_mod.Heap.setHas(out, v)) {
            _ = heap_mod.Heap.setDelete(out, v);
        } else if (!heap_mod.Heap.setHas(s, v)) {
            try rt.heap.setAdd(out, v);
        }
        root_buf[6] = .undefined;
    }
    return Value.fromObject(out);
}

fn setIsSubsetOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "isSubsetOf");
    const rec = try getSetRecord(rt, arg(args, 0));
    if (@as(f64, @floatFromInt(s.kind.set.live_count)) > rec.size) return Value.fromBool(false);

    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var i: usize = 0;
    while (i < s.kind.set.entries.items.len) : (i += 1) {
        const e = s.kind.set.entries.items[i];
        if (!e.alive) continue;
        root_buf[4] = e.key;
        const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
        if (!ops.toBoolean(res)) return Value.fromBool(false);
        root_buf[4] = .undefined;
    }
    return Value.fromBool(true);
}

fn setIsSupersetOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "isSupersetOf");
    const rec = try getSetRecord(rt, arg(args, 0));
    if (@as(f64, @floatFromInt(s.kind.set.live_count)) < rec.size) return Value.fromBool(false);

    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try getSetKeysIterator(rt, rec);
    root_buf[4] = Value.fromObject(iter);
    while (try iteratorNextVal(rt, iter)) |v| {
        root_buf[5] = v;
        if (!heap_mod.Heap.setHas(s, v)) {
            try iteratorClose(rt, iter, false);
            return Value.fromBool(false);
        }
        root_buf[5] = .undefined;
    }
    return Value.fromBool(true);
}

fn setIsDisjointFrom(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const s = try thisSet(rt, this, "isDisjointFrom");
    const rec = try getSetRecord(rt, arg(args, 0));
    var root_buf = [_]Value{ this, rec.obj, rec.has, rec.keys, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (@as(f64, @floatFromInt(s.kind.set.live_count)) <= rec.size) {
        var i: usize = 0;
        while (i < s.kind.set.entries.items.len) : (i += 1) {
            const e = s.kind.set.entries.items[i];
            if (!e.alive) continue;
            root_buf[5] = e.key;
            const res = try rt.callCallable(rec.has, rec.obj, &.{e.key});
            if (ops.toBoolean(res)) return Value.fromBool(false);
            root_buf[5] = .undefined;
        }
    } else {
        const iter = try getSetKeysIterator(rt, rec);
        root_buf[4] = Value.fromObject(iter);
        while (try iteratorNextVal(rt, iter)) |v| {
            root_buf[5] = v;
            if (heap_mod.Heap.setHas(s, v)) {
                try iteratorClose(rt, iter, false);
                return Value.fromBool(false);
            }
            root_buf[5] = .undefined;
        }
    }
    return Value.fromBool(true);
}

// ---------------------------------------------------------------- WeakMap & WeakSet (M45, D75)

const weak_map_get: Native = .{ .name = "get", .length = 1, .call = weakMapGet };
const weak_map_set: Native = .{ .name = "set", .length = 2, .call = weakMapSet };
const weak_map_has: Native = .{ .name = "has", .length = 1, .call = weakMapHas };
const weak_map_delete: Native = .{ .name = "delete", .length = 1, .call = weakMapDelete };

fn weakMapWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor WeakMap requires 'new'" }});
}

fn weakMapConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    const wm = try rt.heap.newWeakMap(r.weak_map_prototype);
    const iterable = arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(wm);

    var root_buf = [_]Value{ iterable, Value.fromObject(wm), .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try requireCallable(rt, try object.get(rt, Value.fromObject(wm), try object.named(rt, "set")));
    root_buf[2] = adder;

    const iter = try getIterator(rt, iterable);
    root_buf[3] = Value.fromObject(iter);

    while (try iteratorNextVal(rt, iter)) |entry| {
        root_buf[4] = entry;
        if (!entry.isObjectLike()) {
            try iteratorClose(rt, iter, true);
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator value is not an entry object" }});
        }
        const k = object.get(rt, entry, .{ .index = 0 }) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[5] = k;
        const v = object.get(rt, entry, .{ .index = 1 }) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[6] = v;
        _ = rt.callCallable(adder, Value.fromObject(wm), &.{ k, v }) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = .undefined;
        root_buf[5] = .undefined;
        root_buf[6] = .undefined;
    }
    return Value.fromObject(wm);
}

fn thisWeakMap(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .weak_map) return this.asObject();
    return rt.throw(.TypeError, &.{ .{ .ascii = "Method WeakMap.prototype." }, .{ .ascii = name }, .{ .ascii = " called on incompatible receiver" } });
}

fn weakMapGet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "get");
    const key = heap_mod.WeakKey.fromValue(arg(args, 0)) orelse return .undefined;
    return heap_mod.Heap.weakMapGet(wm, key) orelse .undefined;
}

fn weakMapSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "set");
    const key = heap_mod.WeakKey.fromValue(arg(args, 0)) orelse return rt.throw(.TypeError, &.{.{ .ascii = "Invalid value used as weak map key" }});
    try rt.heap.weakMapSet(wm, key, arg(args, 1));
    return this;
}

fn weakMapHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "has");
    const key = heap_mod.WeakKey.fromValue(arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakMapHas(wm, key));
}

fn weakMapDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const wm = try thisWeakMap(rt, this, "delete");
    const key = heap_mod.WeakKey.fromValue(arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakMapDelete(wm, key));
}

const weak_set_add: Native = .{ .name = "add", .length = 1, .call = weakSetAdd };
const weak_set_has: Native = .{ .name = "has", .length = 1, .call = weakSetHas };
const weak_set_delete: Native = .{ .name = "delete", .length = 1, .call = weakSetDelete };

fn weakSetWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor WeakSet requires 'new'" }});
}

fn weakSetConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    const ws = try rt.heap.newWeakSet(r.weak_set_prototype);
    const iterable = arg(args, 0);
    if (iterable.isUndefined() or iterable.isNull()) return Value.fromObject(ws);

    var root_buf = [_]Value{ iterable, Value.fromObject(ws), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const adder = try requireCallable(rt, try object.get(rt, Value.fromObject(ws), try object.named(rt, "add")));
    root_buf[2] = adder;

    const iter = try getIterator(rt, iterable);
    root_buf[3] = Value.fromObject(iter);

    while (try iteratorNextVal(rt, iter)) |v| {
        root_buf[4] = v;
        _ = rt.callCallable(adder, Value.fromObject(ws), &.{v}) catch |e| {
            if (e == error.Thrown) try iteratorClose(rt, iter, true);
            return e;
        };
        root_buf[4] = .undefined;
    }
    return Value.fromObject(ws);
}

fn thisWeakSet(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .weak_set) return this.asObject();
    return rt.throw(.TypeError, &.{ .{ .ascii = "Method WeakSet.prototype." }, .{ .ascii = name }, .{ .ascii = " called on incompatible receiver" } });
}

fn weakSetAdd(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const ws = try thisWeakSet(rt, this, "add");
    const key = heap_mod.WeakKey.fromValue(arg(args, 0)) orelse return rt.throw(.TypeError, &.{.{ .ascii = "Invalid value used in weak set" }});
    try rt.heap.weakSetAdd(ws, key);
    return this;
}

fn weakSetHas(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const ws = try thisWeakSet(rt, this, "has");
    const key = heap_mod.WeakKey.fromValue(arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakSetHas(ws, key));
}

fn weakSetDelete(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const ws = try thisWeakSet(rt, this, "delete");
    const key = heap_mod.WeakKey.fromValue(arg(args, 0)) orelse return Value.fromBool(false);
    return Value.fromBool(heap_mod.Heap.weakSetDelete(ws, key));
}

// ---------------------------------------------------------------- Promise (M18)

const promise_resolve_static: Native = .{ .name = "resolve", .call = promiseResolveStatic };
const promise_reject_static: Native = .{ .name = "reject", .call = promiseRejectStatic };
const promise_with_resolvers_static: Native = .{ .name = "withResolvers", .call = promiseWithResolversStatic };
const promise_try_static: Native = .{ .name = "try", .length = 1, .call = promiseTryStatic };
const promise_all_static: Native = .{ .name = "all", .length = 1, .call = promiseAllStatic };
const promise_all_settled_static: Native = .{ .name = "allSettled", .length = 1, .call = promiseAllSettledStatic };
const promise_race_static: Native = .{ .name = "race", .length = 1, .call = promiseRaceStatic };
const promise_any_static: Native = .{ .name = "any", .length = 1, .call = promiseAnyStatic };
const promise_then: Native = .{ .name = "then", .call = promiseThen };
const promise_catch: Native = .{ .name = "catch", .call = promiseCatch };
const promise_finally: Native = .{ .name = "finally", .call = promiseFinally };

fn thisPromise(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .promise) return this.asObject();
    return unsupportedReceiver(rt, name);
}

fn promiseThen(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const p_obj = try thisPromise(rt, this, "then");
    const raw_f = arg(args, 0);
    const raw_r = arg(args, 1);
    const on_fulfilled: Value = if (raw_f.isNative() or raw_f.isClosure()) raw_f else .undefined;
    const on_rejected: Value = if (raw_r.isNative() or raw_r.isClosure()) raw_r else .undefined;

    var root_buf = [_]Value{ Value.fromObject(p_obj), on_fulfilled, on_rejected, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const r = try realm(rt);
    const child = try rt.heap.newPromise(r.promise_prototype);
    root_buf[3] = Value.fromObject(child);
    const pr = &p_obj.kind.promise;

    if (pr.state == .pending) {
        try pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1);
        pr.reactions.appendAssumeCapacity(.{
            .child = child,
            .on_fulfilled = on_fulfilled,
            .on_rejected = on_rejected,
        });
        rt.heap.barrier(&p_obj.obj, null, Value.fromObject(child));
        rt.heap.barrier(&p_obj.obj, null, on_fulfilled);
        rt.heap.barrier(&p_obj.obj, null, on_rejected);
    } else {
        const is_rejected = (pr.state == .rejected);
        const cb = if (is_rejected) on_rejected else on_fulfilled;
        const is_adopt = (!cb.isNative() and !cb.isClosure());
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = if (is_adopt) .adopt else .reaction,
            .child = child,
            .cb = cb,
            .arg = pr.result,
            .adopt_rejected = is_rejected,
        });
    }
    return Value.fromObject(child);
}

/// PerformPromiseThen without a result capability (internal reactions, D68): `p` must be
/// a native promise; the handlers are callables.
pub fn performPromiseThen(rt: *Runtime, p_obj: *Object, on_fulfilled: Value, on_rejected: Value) Error!void {
    return performPromiseThenCap(rt, p_obj, on_fulfilled, on_rejected, null);
}

/// PerformPromiseThen with result promise `child` (or none): a non-callable handler
/// passes the settlement through to `child`.
pub fn performPromiseThenCap(rt: *Runtime, p_obj: *Object, on_fulfilled: Value, on_rejected: Value, child: ?*Object) Error!void {
    const pr = &p_obj.kind.promise;
    if (pr.state == .pending) {
        pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1) catch |e| return rt.heap.failed(e);
        pr.reactions.appendAssumeCapacity(.{ .child = child, .on_fulfilled = on_fulfilled, .on_rejected = on_rejected });
        if (child) |ch| rt.heap.barrierObj(&p_obj.obj, &ch.obj);
        rt.heap.barrier(&p_obj.obj, null, on_fulfilled);
        rt.heap.barrier(&p_obj.obj, null, on_rejected);
    } else {
        const is_rejected = (pr.state == .rejected);
        const cb = if (is_rejected) on_rejected else on_fulfilled;
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = if (cb.isNative() or cb.isClosure()) .reaction else .adopt,
            .child = child,
            .cb = cb,
            .arg = pr.result,
            .adopt_rejected = is_rejected,
        });
    }
}

fn promiseCatch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    _ = try thisPromise(rt, this, "catch");
    return promiseThen(rt, this, &.{ .undefined, arg(args, 0) });
}

fn promiseFinally(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const p_obj = try thisPromise(rt, this, "finally");
    const raw_f = arg(args, 0);
    if (!raw_f.isNative() and !raw_f.isClosure()) {
        return promiseThen(rt, this, &.{ raw_f, raw_f });
    }

    var root_buf = [_]Value{ Value.fromObject(p_obj), raw_f, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const env = try rt.heap.newArray(null);
    root_buf[2] = Value.fromObject(env);
    try rt.heap.appendElements(env, &.{raw_f});

    const then_fn = try rt.heap.newNativeClosure(&finallyThenCb, env);
    root_buf[3] = Value.fromClosure(then_fn);
    const catch_fn = try rt.heap.newNativeClosure(&finallyCatchCb, env);
    root_buf[4] = Value.fromClosure(catch_fn);

    return promiseThen(rt, Value.fromObject(p_obj), &.{ root_buf[3], root_buf[4] });
}

fn finallyThenCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return finallyRunCb(rt, env, arg(args, 0), false);
}

fn finallyCatchCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    return finallyRunCb(rt, env, arg(args, 0), true);
}

fn finallyRunCb(rt: *Runtime, env: *Object, val: Value, is_catch: bool) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(env), val, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const on_finally = env.kind.array.items[0];
    const res = try rt.callCallable(on_finally, .undefined, &.{});
    root_buf[2] = res;
    const p_val = try resolveToPromise(rt, res);
    root_buf[3] = p_val;

    const env2 = try rt.heap.newArray(null);
    root_buf[4] = Value.fromObject(env2);
    try rt.heap.appendElements(env2, &.{val});

    const cb_ptr: *const anyopaque = if (is_catch) &finallyThrower else &finallyValueThunk;
    const cb = try rt.heap.newNativeClosure(cb_ptr, env2);
    root_buf[5] = Value.fromClosure(cb);
    return promiseThen(rt, p_val, &.{root_buf[5]});
}

fn finallyValueThunk(_: *Runtime, env: *Object, _: []const Value) Error!Value {
    return env.kind.array.items[0];
}

fn finallyThrower(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    return rt.throwValue(env.kind.array.items[0]);
}

fn promiseWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Promise requires 'new'" }});
}

fn promiseConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const exec = try requireCallable(rt, arg(args, 0));
    const r = try realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    const res_cap = try rt.heap.newPromiseCapability(p, false);
    const rej_cap = try rt.heap.newPromiseCapability(p, true);
    const p_val: Value = Value.fromObject(p);
    const res_val: Value = Value.fromClosure(res_cap);
    const rej_val: Value = Value.fromClosure(rej_cap);

    var root_buf = [_]Value{ p_val, exec, res_val, rej_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    _ = rt.callCallable(exec, .undefined, &.{ res_val, rej_val }) catch |e| {
        if (e != error.Thrown) return e;
        const err_val = try rt.catchValue();
        if (!p.kind.promise.already_resolved) {
            try settlePromiseFromJob(rt, p, true, err_val);
        }
    };
    return p_val;
}

pub fn resolveToPromise(rt: *Runtime, x: Value) Error!Value {
    const r = try realm(rt);
    if (x.isObject() and x.asObject().kind == .promise and x.asObject().proto == r.promise_prototype) {
        return x;
    }
    const p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ Value.fromObject(p), x };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    try resolvePromiseValue(rt, p, x);
    return Value.fromObject(p);
}

fn promiseResolveStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return resolveToPromise(rt, arg(args, 0));
}

fn promiseRejectStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const reason = arg(args, 0);
    const r = try realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    try settlePromiseFromJob(rt, p, true, reason);
    return Value.fromObject(p);
}

fn promiseWithResolversStatic(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    const r = try realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    const out = try rt.heap.newObject(r.object_prototype);
    var root_buf = [_]Value{ Value.fromObject(p), Value.fromObject(out), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const resolve_fn = try rt.heap.newPromiseCapability(p, false);
    root_buf[2] = Value.fromClosure(resolve_fn);
    const reject_fn = try rt.heap.newPromiseCapability(p, true);
    root_buf[3] = Value.fromClosure(reject_fn);

    try object.define(rt, out, try object.named(rt, "promise"), Value.fromObject(p));
    try object.define(rt, out, try object.named(rt, "resolve"), Value.fromClosure(resolve_fn));
    try object.define(rt, out, try object.named(rt, "reject"), Value.fromClosure(reject_fn));
    return Value.fromObject(out);
}

fn promiseTryStatic(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const cb = arg(args, 0);
    const r = try realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ Value.fromObject(p), cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (!cb.isFunction()) {
        const err_val = try makeEngineError(rt, .TypeError, try rt.heap.ascii("Promise.try requires a callable argument"));
        root_buf[2] = err_val;
        try settlePromiseFromJob(rt, p, true, err_val);
        return Value.fromObject(p);
    }

    const call_args = if (args.len > 1) args[1..] else &[_]Value{};
    const res = rt.callCallable(cb, .undefined, call_args) catch |e| {
        if (e != error.Thrown) return e;
        const err_val = try rt.catchValue();
        root_buf[2] = err_val;
        try settlePromiseFromJob(rt, p, true, err_val);
        return Value.fromObject(p);
    };
    root_buf[2] = res;
    try resolvePromiseValue(rt, p, res);
    return Value.fromObject(p);
}

const CombinatorKind = enum { all, all_settled, race, any };

fn promiseAllStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .all, this, arg(args, 0));
}

fn promiseAllSettledStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .all_settled, this, arg(args, 0));
}

fn promiseRaceStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .race, this, arg(args, 0));
}

fn promiseAnyStatic(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return promiseCombinator(rt, .any, this, arg(args, 0));
}

fn capabilityExecutor(rt: *Runtime, cap_arr: *Object, args: []const Value) Error!Value {
    if (!cap_arr.kind.array.items[0].isUndefined() or !cap_arr.kind.array.items[1].isUndefined()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise capability executor already called" }});
    }
    rt.heap.storeElement(cap_arr, 0, arg(args, 0));
    rt.heap.storeElement(cap_arr, 1, arg(args, 1));
    return .undefined;
}

fn rejectCapabilityCaught(rt: *Runtime, rej_cap: Value, p_out: Value) Error!Value {
    const err_val = try rt.catchValue();
    var root_buf = [_]Value{ p_out, rej_cap, err_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    _ = try rt.callCallable(rej_cap, .undefined, &.{err_val});
    return p_out;
}

fn promiseCombinator(rt: *Runtime, comptime kind: CombinatorKind, ctor: Value, iterable: Value) Error!Value {
    if (!isConstructor(ctor)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Promise combinator requires a constructor" }});
    }
    const r = try realm(rt);

    var root_buf = [_]Value{
        ctor,
        iterable,
        .undefined, // [2] p_out
        .undefined, // [3] res_cap
        .undefined, // [4] rej_cap
        .undefined, // [5] promise_resolve
        .undefined, // [6] iter
        .undefined, // [7] results_arr
        .undefined, // [8] state_arr: [p_out, results_arr, remaining, res_cap, rej_cap, settled]
        .undefined, // [9] elem / next_p
        .undefined, // [10] elem_env: [state_arr, index, called]
        .undefined, // [11] cb_f
        .undefined, // [12] cb_r
    };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const is_builtin_promise = ctor.isNative() and ctor.asNative() == &promise_global;
    if (is_builtin_promise) {
        const p_obj = try rt.heap.newPromise(r.promise_prototype);
        root_buf[2] = Value.fromObject(p_obj);
        root_buf[3] = Value.fromClosure(try rt.heap.newPromiseCapability(p_obj, false));
        root_buf[4] = Value.fromClosure(try rt.heap.newPromiseCapability(p_obj, true));
    } else {
        const cap_arr = try rt.heap.newArray(null);
        root_buf[9] = Value.fromObject(cap_arr);
        try rt.heap.appendElements(cap_arr, &.{ .undefined, .undefined });
        const exec = try rt.heap.newNativeClosure(&capabilityExecutor, cap_arr);
        root_buf[10] = Value.fromClosure(exec);
        root_buf[2] = try constructWithNewTarget(rt, ctor, &.{Value.fromClosure(exec)}, ctor);
        const res_cap = cap_arr.kind.array.items[0];
        const rej_cap = cap_arr.kind.array.items[1];
        if (!res_cap.isFunction() or !rej_cap.isFunction()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Promise resolve or reject function is not callable" }});
        }
        root_buf[3] = res_cap;
        root_buf[4] = rej_cap;
        root_buf[9] = .undefined;
        root_buf[10] = .undefined;
    }

    const p_out = root_buf[2];
    const res_cap = root_buf[3];
    const rej_cap = root_buf[4];

    const promise_resolve = object.get(rt, ctor, try object.named(rt, "resolve")) catch |e| {
        if (e != error.Thrown) return e;
        return rejectCapabilityCaught(rt, rej_cap, p_out);
    };
    root_buf[5] = promise_resolve;
    if (!promise_resolve.isFunction()) {
        const err_val = try makeEngineError(rt, .TypeError, try rt.heap.ascii("Promise resolve is not a function"));
        root_buf[9] = err_val;
        _ = try rt.callCallable(rej_cap, .undefined, &.{err_val});
        return p_out;
    }

    const iter = getIterator(rt, iterable) catch |e| {
        if (e != error.Thrown) return e;
        return rejectCapabilityCaught(rt, rej_cap, p_out);
    };
    root_buf[6] = Value.fromObject(iter);

    if (kind != .race) {
        const results_arr = try rt.heap.newArray(r.array_prototype);
        root_buf[7] = Value.fromObject(results_arr);
        const state_arr = try rt.heap.newArray(null);
        root_buf[8] = Value.fromObject(state_arr);
        try rt.heap.appendElements(state_arr, &.{
            p_out,
            Value.fromObject(results_arr),
            Value.fromNumber(0),
            res_cap,
            rej_cap,
            Value.fromBool(false),
        });
    }

    var count: usize = 0;
    while (true) {
        const maybe_elem = iteratorNextVal(rt, iter) catch |e| {
            if (e != error.Thrown) return e;
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        const elem = maybe_elem orelse break;
        root_buf[9] = elem;

        const next_p = (if (is_builtin_promise and promise_resolve.isNative() and promise_resolve.asNative() == &promise_resolve_static)
            resolveToPromise(rt, elem)
        else
            rt.callCallable(promise_resolve, ctor, &.{elem})) catch |e| {
            if (e != error.Thrown) return e;
            try iteratorClose(rt, iter, true);
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        root_buf[9] = next_p;

        if (kind != .race) {
            try rt.heap.appendElements(root_buf[7].asObject(), &.{.undefined});
            const elem_env = try rt.heap.newArray(null);
            root_buf[10] = Value.fromObject(elem_env);
            try rt.heap.appendElements(elem_env, &.{ root_buf[8], Value.fromNumber(@floatFromInt(count)), Value.fromBool(false) });
        }

        const cb_f: Value = switch (kind) {
            .all => Value.fromClosure(try rt.heap.newNativeClosure(&allFulfillCb, root_buf[10].asObject())),
            .all_settled => Value.fromClosure(try rt.heap.newNativeClosure(&allSettledFulfillCb, root_buf[10].asObject())),
            .race, .any => res_cap,
        };
        root_buf[11] = cb_f;

        const cb_r: Value = switch (kind) {
            .all, .race => rej_cap,
            .all_settled => Value.fromClosure(try rt.heap.newNativeClosure(&allSettledRejectCb, root_buf[10].asObject())),
            .any => Value.fromClosure(try rt.heap.newNativeClosure(&anyRejectCb, root_buf[10].asObject())),
        };
        root_buf[12] = cb_r;

        const then_fn = object.get(rt, next_p, try object.named(rt, "then")) catch |e| {
            if (e != error.Thrown) return e;
            try iteratorClose(rt, iter, true);
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        _ = rt.callCallable(then_fn, next_p, &.{ cb_f, cb_r }) catch |e| {
            if (e != error.Thrown) return e;
            try iteratorClose(rt, iter, true);
            return rejectCapabilityCaught(rt, rej_cap, p_out);
        };
        count += 1;
    }

    if (count == 0) {
        switch (kind) {
            .all, .all_settled => _ = try rt.callCallable(res_cap, .undefined, &.{root_buf[7]}),
            .race => {},
            .any => {
                const agg = try makeAggregateError(rt, root_buf[7]);
                root_buf[9] = agg;
                _ = try rt.callCallable(rej_cap, .undefined, &.{agg});
            },
        }
    } else if (kind != .race) {
        // Set remaining count after iteration so reactions (queued via microtasks) see final count.
        const state_arr = root_buf[8].asObject();
        const cur_rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
        const total_rem = cur_rem + @as(isize, @intCast(count));
        rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(total_rem)));
        if (total_rem == 0 and !state_arr.kind.array.items[5].asBool()) {
            rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
            switch (kind) {
                .all, .all_settled => _ = try rt.callCallable(res_cap, .undefined, &.{root_buf[7]}),
                .any => {
                    const agg = try makeAggregateError(rt, root_buf[7]);
                    root_buf[9] = agg;
                    _ = try rt.callCallable(rej_cap, .undefined, &.{agg});
                },
                .race => unreachable,
            }
        }
    }

    return p_out;
}

fn allFulfillCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    if (elem_env.kind.array.items[2].asBool()) return .undefined;
    rt.heap.storeElement(elem_env, 2, Value.fromBool(true));
    const state_arr = elem_env.kind.array.items[0].asObject();
    if (state_arr.kind.array.items[5].asBool()) return .undefined;

    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].asNumber());
    const results_arr = state_arr.kind.array.items[1].asObject();
    rt.heap.storeElement(results_arr, idx, arg(args, 0));

    const rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(next_rem)));
    if (next_rem == 0) {
        rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
        _ = try rt.callCallable(state_arr.kind.array.items[3], .undefined, &.{Value.fromObject(results_arr)});
    }
    return .undefined;
}

fn allSettledFulfillCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    return allSettledCb(rt, elem_env, arg(args, 0), false);
}

fn allSettledRejectCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    return allSettledCb(rt, elem_env, arg(args, 0), true);
}

fn allSettledCb(rt: *Runtime, elem_env: *Object, val: Value, is_rejected: bool) Error!Value {
    if (elem_env.kind.array.items[2].asBool()) return .undefined;
    rt.heap.storeElement(elem_env, 2, Value.fromBool(true));
    const state_arr = elem_env.kind.array.items[0].asObject();
    if (state_arr.kind.array.items[5].asBool()) return .undefined;

    var root_buf = [_]Value{ Value.fromObject(elem_env), val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const r = try realm(rt);
    const obj = try rt.heap.newObject(r.object_prototype);
    root_buf[2] = Value.fromObject(obj);
    const status_str = try rt.heap.newString(&.{.{ .ascii = if (is_rejected) "rejected" else "fulfilled" }});
    root_buf[3] = Value.fromString(status_str);
    try object.define(rt, obj, try object.named(rt, "status"), root_buf[3]);
    try object.define(rt, obj, try object.named(rt, if (is_rejected) "reason" else "value"), val);

    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].asNumber());
    const results_arr = state_arr.kind.array.items[1].asObject();

    rt.heap.storeElement(results_arr, idx, root_buf[2]);
    const rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(next_rem)));
    if (next_rem == 0) {
        rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
        _ = try rt.callCallable(state_arr.kind.array.items[3], .undefined, &.{Value.fromObject(results_arr)});
    }
    return .undefined;
}

fn anyRejectCb(rt: *Runtime, elem_env: *Object, args: []const Value) Error!Value {
    if (elem_env.kind.array.items[2].asBool()) return .undefined;
    rt.heap.storeElement(elem_env, 2, Value.fromBool(true));
    const state_arr = elem_env.kind.array.items[0].asObject();
    if (state_arr.kind.array.items[5].asBool()) return .undefined;

    const idx: usize = @intFromFloat(elem_env.kind.array.items[1].asNumber());
    const errors_arr = state_arr.kind.array.items[1].asObject();
    rt.heap.storeElement(errors_arr, idx, arg(args, 0));

    const rem: isize = @intFromFloat(state_arr.kind.array.items[2].asNumber());
    const next_rem = rem - 1;
    rt.heap.storeElement(state_arr, 2, Value.fromNumber(@floatFromInt(next_rem)));
    if (next_rem == 0) {
        rt.heap.storeElement(state_arr, 5, Value.fromBool(true));
        var root_buf = [_]Value{ Value.fromObject(state_arr), Value.fromObject(errors_arr), .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const agg = try makeAggregateError(rt, Value.fromObject(errors_arr));
        root_buf[2] = agg;
        _ = try rt.callCallable(state_arr.kind.array.items[4], .undefined, &.{agg});
    }
    return .undefined;
}

fn makeAggregateError(rt: *Runtime, errors_arr_val: Value) Error!Value {
    const r = try realm(rt);
    var root_buf = [_]Value{ errors_arr_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(r.aggregate_error_prototype);
    err_obj.ordinary_tag = .@"error";
    root_buf[1] = Value.fromObject(err_obj);
    const msg_str = try rt.heap.newString(&.{.{ .ascii = "All promises were rejected" }});
    root_buf[2] = Value.fromString(msg_str);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[2], .enumerable = false });
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("errors"), .{ .value = errors_arr_val, .enumerable = false });
    return root_buf[1];
}

pub fn callPromiseCapability(rt: *Runtime, p_obj: *Object, is_reject: bool, args: []const Value) Error!Value {
    if (p_obj.kind.promise.already_resolved) return .undefined;
    const val = arg(args, 0);
    var root_buf = [_]Value{ Value.fromObject(p_obj), val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (is_reject) {
        try settlePromiseFromJob(rt, p_obj, true, val);
    } else {
        try resolvePromiseValue(rt, p_obj, val);
    }
    return .undefined;
}

/// Atomic Promise resolution: all allocations and queue reservations succeed
/// before any Promise state or reaction list is mutated.
pub fn resolvePromiseValue(rt: *Runtime, p_obj: *Object, val: Value) Error!void {
    if (val.isObject() and val.asObject() == p_obj) {
        const r = try realm(rt);
        var err_roots_buf = [_]Value{ Value.fromObject(p_obj), .undefined, .undefined };
        var err_roots: rt_mod.ValueRoots = .{ .values = &err_roots_buf };
        try err_roots.register(rt);
        defer err_roots.unregister(rt);

        const err_obj = try rt.heap.newObject(r.type_error_prototype);
        err_obj.ordinary_tag = .@"error";
        err_roots_buf[1] = Value.fromObject(err_obj);
        const msg_str = try rt.heap.newString(&.{.{ .ascii = "Chaining cycle detected for promise" }});
        err_roots_buf[2] = Value.fromString(msg_str);
        try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = err_roots_buf[2], .enumerable = false });
        try settlePromiseFromJob(rt, p_obj, true, err_roots_buf[1]);
        return;
    }

    if (val.isObject() and val.asObject().kind == .promise) {
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        p_obj.kind.promise.already_resolved = true;
        rt.microtasks.appendAssumeCapacity(.{
            .kind = .resolve_promise,
            .child = p_obj,
            .cb = .undefined,
            .arg = val,
        });
        return;
    }

    if (val.isObjectLike()) {
        var root_buf = [_]Value{ Value.fromObject(p_obj), val, .undefined, .undefined, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const then_val = object.get(rt, val, try object.named(rt, "then")) catch |e| {
            if (e == error.Thrown) {
                try settlePromiseFromJob(rt, p_obj, true, try rt.catchValue());
                return;
            }
            return e;
        };
        root_buf[2] = then_val;
        if (then_val.isFunction()) {
            const env = try rt.heap.newArray(null);
            root_buf[3] = Value.fromObject(env);
            try rt.heap.appendElements(env, &.{ Value.fromObject(p_obj), val, then_val, Value.fromBool(false) });
            const job_cb = try rt.heap.newNativeClosure(&thenableJobCb, env);
            root_buf[4] = Value.fromClosure(job_cb);
            try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
            p_obj.kind.promise.already_resolved = true;
            rt.microtasks.appendAssumeCapacity(.{
                .kind = .reaction,
                .child = null,
                .cb = root_buf[4],
                .arg = .undefined,
            });
            return;
        }
    }

    try settlePromiseFromJob(rt, p_obj, false, val);
}

fn thenableJobCb(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(env), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const res_fn = try rt.heap.newNativeClosure(&thenableResolveCb, env);
    root_buf[1] = Value.fromClosure(res_fn);
    const rej_fn = try rt.heap.newNativeClosure(&thenableRejectCb, env);
    root_buf[2] = Value.fromClosure(rej_fn);

    _ = rt.callCallable(env.kind.array.items[2], env.kind.array.items[1], &.{ root_buf[1], root_buf[2] }) catch |e| {
        if (e == error.Thrown) {
            if (!env.kind.array.items[3].asBool()) {
                rt.heap.storeElement(env, 3, Value.fromBool(true));
                try settlePromiseFromJob(rt, env.kind.array.items[0].asObject(), true, try rt.catchValue());
            } else {
                _ = rt.catchValue() catch {};
            }
            return .undefined;
        }
        return e;
    };
    return .undefined;
}

fn thenableResolveCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    if (env.kind.array.items[3].asBool()) return .undefined;
    rt.heap.storeElement(env, 3, Value.fromBool(true));
    try resolvePromiseValue(rt, env.kind.array.items[0].asObject(), arg(args, 0));
    return .undefined;
}

fn thenableRejectCb(rt: *Runtime, env: *Object, args: []const Value) Error!Value {
    if (env.kind.array.items[3].asBool()) return .undefined;
    rt.heap.storeElement(env, 3, Value.fromBool(true));
    try settlePromiseFromJob(rt, env.kind.array.items[0].asObject(), true, arg(args, 0));
    return .undefined;
}

pub fn adoptPromiseNow(rt: *Runtime, p_obj: *Object, other: *Object) Error!void {
    const other_pr = &other.kind.promise;
    if (other_pr.state == .pending) {
        try other_pr.reactions.ensureUnusedCapacity(rt.heap.allocator(), 1);
        other_pr.reactions.appendAssumeCapacity(.{ .child = p_obj, .on_fulfilled = .undefined, .on_rejected = .undefined });
        rt.heap.barrier(&other.obj, null, Value.fromObject(p_obj));
    } else {
        try rt.microtasks.ensureUnusedCapacity(rt.gpa, 1);
        rt.microtasks.appendAssumeCapacity(.{
            .kind = .adopt,
            .child = p_obj,
            .cb = .undefined,
            .arg = other_pr.result,
            .adopt_rejected = (other_pr.state == .rejected),
        });
    }
}

/// Atomic Promise settlement: reserves microtask queue capacity before mutating
/// Promise state or moving reactions.
pub fn settlePromiseFromJob(rt: *Runtime, p_obj: *Object, is_rejected: bool, val: Value) Error!void {
    const pr = &p_obj.kind.promise;
    if (pr.state != .pending) return;
    try rt.microtasks.ensureUnusedCapacity(rt.gpa, pr.reactions.items.len);

    pr.already_resolved = true;
    pr.state = if (is_rejected) .rejected else .fulfilled;
    rt.heap.barrier(&p_obj.obj, pr.result, val);
    pr.result = val;

    for (pr.reactions.items) |rx| {
        if (rx.coroutine) |co| {
            rt.microtasks.appendAssumeCapacity(.{
                .kind = .await_resume,
                .coroutine = co,
                .arg = val,
                .adopt_rejected = is_rejected,
            });
            continue;
        }
        const cb = if (is_rejected) rx.on_rejected else rx.on_fulfilled;
        const is_adopt = (!cb.isNative() and !cb.isClosure());
        rt.microtasks.appendAssumeCapacity(.{
            .kind = if (is_adopt) .adopt else .reaction,
            .child = rx.child,
            .cb = cb,
            .arg = val,
            .adopt_rejected = is_rejected,
        });
    }
    pr.reactions.clearRetainingCapacity();
}

// ---------------------------------------------------------------- Iterators (M14.4, M36 D66)

const iterator_next: Native = .{ .name = "next", .call = iteratorNext };
const string_iterator: Native = .{ .name = "[Symbol.iterator]", .call = stringIterator };
const iterator_self: Native = .{ .name = "[Symbol.iterator]", .call = iteratorSelf };

fn stringIterator(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const s = try thisString(rt, this, "[Symbol.iterator]");
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, Value.fromString(s), .string_chars));
}

fn iteratorSelf(_: *Runtime, this: Value, _: []const Value) Error!Value {
    return this;
}

// ---------------------------------------------------------------- ES2025 Iterator Helpers

const iterator_from: Native = .{ .name = "from", .length = 1, .call = iteratorFrom };
const iterator_proto_ctor_get: Native = .{ .name = "get constructor", .call = iteratorProtoCtorGet };
const iterator_proto_ctor_set: Native = .{ .name = "set constructor", .length = 1, .call = iteratorProtoCtorSet };
const iterator_proto_tag_get: Native = .{ .name = "get [Symbol.toStringTag]", .call = iteratorProtoTagGet };
const iterator_proto_tag_set: Native = .{ .name = "set [Symbol.toStringTag]", .length = 1, .call = iteratorProtoTagSet };
const iterator_map: Native = .{ .name = "map", .length = 1, .call = iteratorMap };
const iterator_filter: Native = .{ .name = "filter", .length = 1, .call = iteratorFilter };
const iterator_take: Native = .{ .name = "take", .length = 1, .call = iteratorTake };
const iterator_drop: Native = .{ .name = "drop", .length = 1, .call = iteratorDrop };
const iterator_flat_map: Native = .{ .name = "flatMap", .length = 1, .call = iteratorFlatMap };
const iterator_reduce: Native = .{ .name = "reduce", .length = 1, .call = iteratorReduce };
const iterator_to_array: Native = .{ .name = "toArray", .length = 0, .call = iteratorToArray };
const iterator_for_each: Native = .{ .name = "forEach", .length = 1, .call = iteratorForEach };
const iterator_some: Native = .{ .name = "some", .length = 1, .call = iteratorSome };
const iterator_every: Native = .{ .name = "every", .length = 1, .call = iteratorEvery };
const iterator_find: Native = .{ .name = "find", .length = 1, .call = iteratorFind };
const iterator_helper_next: Native = .{ .name = "next", .length = 0, .call = iteratorHelperNext };
const iterator_helper_return: Native = .{ .name = "return", .length = 0, .call = iteratorHelperReturn };
const iterator_wrap_next: Native = .{ .name = "next", .length = 0, .call = iteratorWrapNext };
const iterator_wrap_return: Native = .{ .name = "return", .length = 0, .call = iteratorWrapReturn };

fn iteratorWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Iterator requires 'new'" }});
}

fn iteratorConstruct(rt: *Runtime, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Abstract class Iterator not directly constructable" }});
}

fn iteratorProtoCtorGet(_: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromNative(&iterator_global);
}

fn iteratorProtoCtorSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.constructor setter called on non-object" }});
    }
    if (this.isObject() and this.asObject() == r.iterator_prototype) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot set constructor on Iterator.prototype" }});
    }
    const v = arg(args, 0);
    const k = try object.named(rt, "constructor");
    if (this.isObject()) {
        if (try object.ownProp(rt, this.asObject(), k)) |_| {
            try object.setStrict(rt, this, k, v);
            return .undefined;
        }
        try object.define(rt, this.asObject(), k, v);
        return .undefined;
    }
    try object.setStrict(rt, this, k, v);
    return .undefined;
}

fn iteratorProtoTagGet(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromString(try rt.heap.ascii("Iterator"));
}

fn iteratorProtoTagSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const r = try realm(rt);
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype[Symbol.toStringTag] setter called on non-object" }});
    }
    if (this.isObject() and this.asObject() == r.iterator_prototype) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot set Symbol.toStringTag on Iterator.prototype" }});
    }
    const v = arg(args, 0);
    const k: object.Key = .{ .symbol = r.sym_to_string_tag };
    if (this.isObject()) {
        if (try object.ownProp(rt, this.asObject(), k)) |_| {
            try object.setStrict(rt, this, k, v);
            return .undefined;
        }
        try object.define(rt, this.asObject(), k, v);
        return .undefined;
    }
    try object.setStrict(rt, this, k, v);
    return .undefined;
}

fn iteratorCloseDirect(rt: *Runtime, iter: Value, is_throw: bool) Error!void {
    if (!iter.isObjectLike()) return;
    if (is_throw) {
        const saved_thrown = rt.thrown_value;
        const saved_exc = rt.exception;
        rt.thrown_value = null;
        rt.exception = null;
        if (object.getMethod(rt, iter, try object.named(rt, "return")) catch null) |ret_fn| {
            _ = rt.callCallable(ret_fn, iter, &.{}) catch {};
        }
        rt.thrown_value = saved_thrown;
        rt.exception = saved_exc;
        return;
    }
    if (try object.getMethod(rt, iter, try object.named(rt, "return"))) |ret_fn| {
        const res = try rt.callCallable(ret_fn, iter, &.{});
        if (!res.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator return result is not an object" }});
        }
    }
}

fn iteratorStepDirect(rt: *Runtime, iter: Value, next_method: Value) Error!?Value {
    const res = try rt.callCallable(next_method, iter, &.{});
    if (!res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    }
    var root_buf = [_]Value{res};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const done = try object.get(rt, res, try object.named(rt, "done"));
    if (ops.toBoolean(done)) return null;
    return try object.get(rt, res, try object.named(rt, "value"));
}

fn makeIterResult(rt: *Runtime, val: Value, done: bool) Error!Value {
    const r = try realm(rt);
    var root_buf = [_]Value{ val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const o = try rt.heap.newObject(r.object_prototype);
    root_buf[1] = Value.fromObject(o);
    try object.define(rt, o, try object.named(rt, "value"), val);
    try object.define(rt, o, try object.named(rt, "done"), Value.fromBool(done));
    return Value.fromObject(o);
}

fn iteratorFrom(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const o = arg(args, 0);
    if (!o.isObjectLike() and !o.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.from called on non-object" }});
    }
    const r = try realm(rt);
    var root_buf = [_]Value{ o, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var iter_val: Value = o;
    if (try object.getMethod(rt, o, .{ .symbol = r.sym_iterator })) |iter_fn| {
        iter_val = try rt.callCallable(iter_fn, o, &.{});
        root_buf[1] = iter_val;
        if (!iter_val.isObjectLike()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.from: Symbol.iterator did not return an object" }});
        }
    }
    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    root_buf[2] = next_fn;

    // If iter_val already inherits from Iterator.prototype, return it directly.
    if (try object.ordinaryHasInstance(rt, Value.fromNative(&iterator_global), iter_val)) {
        return iter_val;
    }

    const env = try rt.heap.newArray(null);
    root_buf[3] = Value.fromObject(env);
    try rt.heap.appendElements(env, &.{ iter_val, next_fn });
    return Value.fromObject(try rt.heap.newIterator(r.iterator_wrap_prototype, root_buf[3], .wrap));
}

fn iteratorWrapNextVal(rt: *Runtime, iter: *Object) Error!?Value {
    const env = iter.kind.iterator.target.asObject();
    return iteratorStepDirect(rt, env.kind.array.items[0], env.kind.array.items[1]);
}

fn iteratorWrapNext(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .wrap) {
        return rt.throw(.TypeError, &.{.{ .ascii = "WrapForValidIterator.next called on incompatible receiver" }});
    }
    const env = this.asObject().kind.iterator.target.asObject();
    return rt.callCallable(env.kind.array.items[1], env.kind.array.items[0], &.{});
}

fn iteratorWrapReturn(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .wrap) {
        return rt.throw(.TypeError, &.{.{ .ascii = "WrapForValidIterator.return called on incompatible receiver" }});
    }
    const env = this.asObject().kind.iterator.target.asObject();
    const underlying = env.kind.array.items[0];
    if (try object.getMethod(rt, underlying, try object.named(rt, "return"))) |ret_fn| {
        return rt.callCallable(ret_fn, underlying, &.{});
    }
    return makeIterResult(rt, .undefined, true);
}

// Helper env layout:
// [0]=kind (0=map, 1=filter, 2=take, 3=drop, 4=flatMap)
// [1]=underlying iter, [2]=underlying next_method, [3]=fn or remaining,
// [4]=counter, [5]=state (0=suspendedStart, 1=executing, 2=completed),
// [6]=inner_iter (flatMap), [7]=inner_next (flatMap)
fn newIteratorHelper(rt: *Runtime, kind_id: f64, iter: Value, next_fn: Value, param: Value) Error!Value {
    const r = try realm(rt);
    const env = try rt.heap.newArray(null);
    var root_buf = [_]Value{ iter, next_fn, param, Value.fromObject(env) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.appendElements(env, &.{
        Value.fromNumber(kind_id),
        iter,
        next_fn,
        param,
        Value.fromNumber(0),
        Value.fromNumber(0),
        .undefined,
        .undefined,
    });
    return Value.fromObject(try rt.heap.newIterator(r.iterator_helper_prototype, Value.fromObject(env), .helper));
}

fn iteratorMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.map called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.map callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, 0, this, next_fn, cb);
}

fn iteratorFilter(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.filter called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.filter callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, 1, this, next_fn, cb);
}

fn iteratorTakeOrDrop(rt: *Runtime, this: Value, args: []const Value, kind_id: f64) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator helper called on non-object" }});
    var root_buf = [_]Value{ this, arg(args, 0), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const num_lim = ops.toNumber(rt, root_buf[1]) catch |e| {
        if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
        return e;
    };
    if (std.math.isNan(num_lim)) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.RangeError, &.{.{ .ascii = "Iterator limit must not be NaN" }});
    }
    const int_lim = if (!std.math.isFinite(num_lim) or num_lim == 0.0) num_lim else @trunc(num_lim);
    if (int_lim < 0.0) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.RangeError, &.{.{ .ascii = "Iterator limit must be non-negative" }});
    }
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, kind_id, this, next_fn, Value.fromNumber(if (int_lim == 0.0) 0.0 else int_lim));
}

fn iteratorTake(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return iteratorTakeOrDrop(rt, this, args, 2);
}

fn iteratorDrop(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return iteratorTakeOrDrop(rt, this, args, 3);
}

fn iteratorFlatMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.flatMap called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.flatMap callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    return newIteratorHelper(rt, 4, this, next_fn, cb);
}

fn iteratorHelperNextVal(rt: *Runtime, iter: *Object) Error!?Value {
    const env = iter.kind.iterator.target.asObject();
    const state = env.kind.array.items[5].asNumber();
    if (state == 2.0) return null;
    if (state == 1.0) return rt.throw(.TypeError, &.{.{ .ascii = "Generator is already executing" }});

    var root_buf = [_]Value{ Value.fromObject(iter), Value.fromObject(env), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    rt.heap.storeElement(env, 5, Value.fromNumber(1.0));
    errdefer rt.heap.storeElement(env, 5, Value.fromNumber(2.0));

    const kind_id: u8 = @intFromFloat(env.kind.array.items[0].asNumber());
    const underlying = env.kind.array.items[1];
    const next_fn = env.kind.array.items[2];

    switch (kind_id) {
        0 => { // map
            const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                return null;
            };
            root_buf[2] = val;
            const counter = env.kind.array.items[4].asNumber();
            rt.heap.storeElement(env, 4, Value.fromNumber(counter + 1.0));
            const mapped = rt.callCallable(env.kind.array.items[3], .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
                if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                return e;
            };
            rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
            return mapped;
        },
        1 => { // filter
            while (true) {
                const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                    return null;
                };
                root_buf[2] = val;
                const counter = env.kind.array.items[4].asNumber();
                rt.heap.storeElement(env, 4, Value.fromNumber(counter + 1.0));
                const keep = rt.callCallable(env.kind.array.items[3], .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
                    if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                    return e;
                };
                if (ops.toBoolean(keep)) {
                    rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
                    return root_buf[2];
                }
            }
        },
        2 => { // take
            const rem = env.kind.array.items[3].asNumber();
            if (rem == 0.0) {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                try iteratorCloseDirect(rt, underlying, false);
                return null;
            }
            if (std.math.isFinite(rem)) rt.heap.storeElement(env, 3, Value.fromNumber(rem - 1.0));
            const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                return null;
            };
            rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
            return val;
        },
        3 => { // drop
            var rem = env.kind.array.items[3].asNumber();
            while (rem > 0.0) {
                if (std.math.isFinite(rem)) {
                    rem -= 1.0;
                    rt.heap.storeElement(env, 3, Value.fromNumber(rem));
                }
                if ((try iteratorStepDirect(rt, underlying, next_fn)) == null) {
                    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                    return null;
                }
            }
            const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                return null;
            };
            rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
            return val;
        },
        4 => { // flatMap
            const r = try realm(rt);
            while (true) {
                if (!env.kind.array.items[6].isUndefined()) {
                    const inner_iter = env.kind.array.items[6];
                    const inner_next = env.kind.array.items[7];
                    const maybe_inner = iteratorStepDirect(rt, inner_iter, inner_next) catch |e| {
                        rt.heap.storeElement(env, 6, .undefined);
                        rt.heap.storeElement(env, 7, .undefined);
                        if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                        return e;
                    };
                    if (maybe_inner) |iv| {
                        rt.heap.storeElement(env, 5, Value.fromNumber(0.0));
                        return iv;
                    }
                    rt.heap.storeElement(env, 6, .undefined);
                    rt.heap.storeElement(env, 7, .undefined);
                }
                const val = (try iteratorStepDirect(rt, underlying, next_fn)) orelse {
                    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
                    return null;
                };
                root_buf[2] = val;
                const counter = env.kind.array.items[4].asNumber();
                rt.heap.storeElement(env, 4, Value.fromNumber(counter + 1.0));
                const mapped = rt.callCallable(env.kind.array.items[3], .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
                    if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                    return e;
                };
                root_buf[2] = mapped;
                if (!mapped.isObjectLike()) {
                    try iteratorCloseDirect(rt, underlying, false);
                    return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.flatMap mapper did not return an object" }});
                }
                const inner_iter: Value = blk: {
                    const maybe_sym = object.getMethod(rt, mapped, .{ .symbol = r.sym_iterator }) catch |e| {
                        if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                        return e;
                    };
                    if (maybe_sym) |iter_m| {
                        const res = rt.callCallable(iter_m, mapped, &.{}) catch |e| {
                            if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                            return e;
                        };
                        if (!res.isObjectLike()) {
                            try iteratorCloseDirect(rt, underlying, false);
                            return rt.throw(.TypeError, &.{.{ .ascii = "flatMap inner iterator is not an object" }});
                        }
                        break :blk res;
                    }
                    break :blk mapped;
                };
                root_buf[3] = inner_iter;
                const inner_next = object.get(rt, inner_iter, try object.named(rt, "next")) catch |e| {
                    if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
                    return e;
                };
                rt.heap.storeElement(env, 6, inner_iter);
                rt.heap.storeElement(env, 7, inner_next);
            }
        },
        else => unreachable,
    }
}

fn iteratorHelperNext(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .helper) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator Helper.next called on incompatible receiver" }});
    }
    if (try iteratorHelperNextVal(rt, this.asObject())) |v| {
        return makeIterResult(rt, v, false);
    }
    return makeIterResult(rt, .undefined, true);
}

fn iteratorHelperReturn(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator or this.asObject().kind.iterator.kind != .helper) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator Helper.return called on incompatible receiver" }});
    }
    const env = this.asObject().kind.iterator.target.asObject();
    const state = env.kind.array.items[5].asNumber();
    if (state == 1.0) return rt.throw(.TypeError, &.{.{ .ascii = "Generator is already executing" }});
    if (state == 2.0) return makeIterResult(rt, .undefined, true);

    var root_buf = [_]Value{ this, Value.fromObject(env) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    rt.heap.storeElement(env, 5, Value.fromNumber(2.0));
    const inner_iter = env.kind.array.items[6];
    const underlying = env.kind.array.items[1];
    if (!inner_iter.isUndefined()) {
        rt.heap.storeElement(env, 6, .undefined);
        rt.heap.storeElement(env, 7, .undefined);
        iteratorCloseDirect(rt, inner_iter, false) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, underlying, true);
            return e;
        };
    }
    try iteratorCloseDirect(rt, underlying, false);
    return makeIterResult(rt, .undefined, true);
}

fn iteratorToArray(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.toArray called on non-object" }});
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ this, Value.fromObject(out), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| {
        root_buf[3] = val;
        try rt.heap.appendElement(out, val);
        root_buf[3] = .undefined;
    }
    return Value.fromObject(out);
}

fn iteratorForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.forEach called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.forEach callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        _ = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        root_buf[3] = .undefined;
    }
    return .undefined;
}

fn iteratorReduce(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.reduce called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.reduce callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, arg(args, 1), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[3] = next_fn;
    var counter: f64 = 0;
    if (args.len < 2) {
        const first = (try iteratorStepDirect(rt, this, next_fn)) orelse {
            return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty iterator with no initial value" }});
        };
        root_buf[2] = first;
        counter = 1;
    }
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[4] = val;
        root_buf[2] = rt.callCallable(cb, .undefined, &.{ root_buf[2], val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        root_buf[4] = .undefined;
    }
    return root_buf[2];
}

fn iteratorSome(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.some called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.some callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        const res = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        if (ops.toBoolean(res)) {
            try iteratorCloseDirect(rt, this, false);
            return Value.fromBool(true);
        }
        root_buf[3] = .undefined;
    }
    return Value.fromBool(false);
}

fn iteratorEvery(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.every called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.every callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        const res = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        if (!ops.toBoolean(res)) {
            try iteratorCloseDirect(rt, this, false);
            return Value.fromBool(false);
        }
        root_buf[3] = .undefined;
    }
    return Value.fromBool(true);
}

fn iteratorFind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.find called on non-object" }});
    const cb = arg(args, 0);
    if (!cb.isFunction()) {
        try iteratorCloseDirect(rt, this, false);
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator.prototype.find callback is not callable" }});
    }
    var root_buf = [_]Value{ this, cb, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const next_fn = try object.get(rt, this, try object.named(rt, "next"));
    root_buf[2] = next_fn;
    var counter: f64 = 0;
    while (try iteratorStepDirect(rt, this, next_fn)) |val| : (counter += 1) {
        root_buf[3] = val;
        const res = rt.callCallable(cb, .undefined, &.{ val, Value.fromNumber(counter) }) catch |e| {
            if (e == error.Thrown) try iteratorCloseDirect(rt, this, true);
            return e;
        };
        if (ops.toBoolean(res)) {
            try iteratorCloseDirect(rt, this, false);
            return root_buf[3];
        }
        root_buf[3] = .undefined;
    }
    return .undefined;
}

pub fn getIterator(rt: *Runtime, iterable: Value) Error!*Object {
    if (iterable.isUndefined() or iterable.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not iterable" }});
    }
    const r = try realm(rt);
    var root_buf = [_]Value{ iterable, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const method_fn = try object.get(rt, iterable, .{ .symbol = r.sym_iterator });
    root_buf[1] = method_fn;
    if (method_fn.isUndefined() or method_fn.isNull() or !method_fn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not iterable" }});
    }
    return getIteratorWithMethod(rt, iterable, method_fn);
}

fn getIteratorWithMethod(rt: *Runtime, iterable: Value, method_fn: Value) Error!*Object {
    const r = try realm(rt);
    var root_buf = [_]Value{ iterable, method_fn, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter_val = try rt.callCallable(method_fn, iterable, &.{});
    root_buf[2] = iter_val;
    if (!iter_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Result of the Symbol.iterator method is not an object" }});
    }
    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    root_buf[3] = next_fn;
    if (iter_val.isObject() and iter_val.asObject().kind == .iterator and
        next_fn.isNative() and next_fn.asNative() == &iterator_next)
    {
        return iter_val.asObject();
    }
    return rt.heap.newCustomIterator(r.iterator_prototype, iter_val, next_fn);
}

fn makePairArray(rt: *Runtime, a: Value, b: Value) Error!Value {
    const r = try realm(rt);
    const pair = try rt.heap.newArray(r.array_prototype);
    try rt.heap.appendElements(pair, &.{ a, b });
    return Value.fromObject(pair);
}

pub fn iteratorNextVal(rt: *Runtime, iter: *Object) Error!?Value {
    const it = &iter.kind.iterator;
    if (it.done) return null;
    switch (it.kind) {
        .for_in => unreachable,
        .map_entries, .map_keys, .map_values => {
            const entries = it.target.asObject().kind.map.entries.items;
            while (it.cursor < entries.len) {
                const i = it.cursor;
                it.cursor += 1;
                const e = entries[i];
                if (!e.alive) continue;
                return switch (it.kind) {
                    .map_entries => try makePairArray(rt, e.key, e.value),
                    .map_keys => e.key,
                    .map_values => e.value,
                    else => unreachable,
                };
            }
        },
        .set_values, .set_entries => {
            const entries = it.target.asObject().kind.set.entries.items;
            while (it.cursor < entries.len) {
                const i = it.cursor;
                it.cursor += 1;
                const e = entries[i];
                if (!e.alive) continue;
                return switch (it.kind) {
                    .set_values => e.key,
                    .set_entries => try makePairArray(rt, e.key, e.key),
                    else => unreachable,
                };
            }
        },
        .array_values, .array_keys, .array_entries => {
            if (it.target.asObject().kind == .typed_array) {
                const ta = it.target.asObject().kind.typed_array;
                if (!ta.buffer.kind.array_buffer.detached and it.cursor < ta.length) {
                    const i = it.cursor;
                    it.cursor += 1;
                    const idx_val: Value = Value.fromNumber(@floatFromInt(i));
                    return switch (it.kind) {
                        .array_values => try object.readTypedArrayElement(rt, ta, i),
                        .array_keys => idx_val,
                        .array_entries => try makePairArray(rt, idx_val, try object.readTypedArrayElement(rt, ta, i)),
                        else => unreachable,
                    };
                }
            } else if (it.target.isObject() and it.target.asObject().kind == .array) {
                const items = it.target.asObject().kind.array.items;
                if (it.cursor < items.len) {
                    const i = it.cursor;
                    it.cursor += 1;
                    const idx_val: Value = Value.fromNumber(@floatFromInt(i));
                    return switch (it.kind) {
                        .array_values => items[i],
                        .array_keys => idx_val,
                        .array_entries => try makePairArray(rt, idx_val, items[i]),
                        else => unreachable,
                    };
                }
            } else {
                // Generic array-like iteration (e.g. `arguments` or `Array.prototype.values.call(obj)`).
                var root_buf = [_]Value{ Value.fromObject(iter), it.target };
                var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
                try roots.register(rt);
                defer roots.unregister(rt);
                const len_val = try object.get(rt, it.target, .{ .atom = try rt.heap.internUtf8("length") });
                const len = try toLength(rt, len_val);
                if (@as(f64, @floatFromInt(it.cursor)) < len) {
                    const i = it.cursor;
                    it.cursor += 1;
                    const idx_val: Value = Value.fromNumber(@floatFromInt(i));
                    if (it.kind == .array_keys) return idx_val;
                    const elem = try object.get(rt, it.target, try object.key(rt, idx_val));
                    return switch (it.kind) {
                        .array_values => elem,
                        .array_entries => try makePairArray(rt, idx_val, elem),
                        else => unreachable,
                    };
                }
            }
        },
        .string_chars => {
            const units = it.target.asString().units;
            if (it.cursor < units.len) {
                const start = it.cursor;
                const first = units[start];
                const step: usize = if (first >= 0xD800 and first <= 0xDBFF and
                    start + 1 < units.len and
                    units[start + 1] >= 0xDC00 and units[start + 1] <= 0xDFFF) 2 else 1;
                it.cursor += step;
                return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = units[start .. start + step] }}));
            }
        },
        .async_from_sync => return rt.bug("a sync step on an async-from-sync iterator"),
        .helper => return iteratorHelperNextVal(rt, iter),
        .wrap => return iteratorWrapNextVal(rt, iter),
        .regexp_match_all => {
            const rx_obj = it.target.asObject();
            const s = it.next_method.asString();
            var root_buf = [_]Value{ Value.fromObject(iter), Value.fromObject(rx_obj), Value.fromString(s), .undefined };
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);

            const match_val = try regexpExecImpl(rt, rx_obj, s);
            if (match_val.isNull()) {
                it.done = true;
                it.target = .undefined;
                it.next_method = .undefined;
                return null;
            }
            root_buf[3] = match_val;
            const match_str = try toStringObj(rt, match_val.asObject().kind.array.items[0]);
            if (match_str.units.len == 0) {
                const this_idx = try toLength(rt, rx_obj.kind.regexp.last_index);
                const is_unicode = rx_obj.kind.regexp.program.flags.isUnicodeMode();
                const next_idx = advanceStringIndex(s.units, @intFromFloat(this_idx), is_unicode);
                rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(@floatFromInt(next_idx)));
            }
            return match_val;
        },
        .custom => {
            var root_buf = [_]Value{ Value.fromObject(iter), .undefined };
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);

            // Per ES IteratorStep: if next() throws, IteratorClose is not called.
            errdefer {
                it.done = true;
                it.target = .undefined;
                it.next_method = .undefined;
            }
            if (!it.next_method.isFunction()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
            }
            const res = try rt.callCallable(it.next_method, it.target, &.{});
            root_buf[1] = res;
            if (!res.isObjectLike()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
            }
            const done_val = try object.get(rt, res, try object.named(rt, "done"));
            if (!ops.toBoolean(done_val)) {
                return try object.get(rt, res, try object.named(rt, "value"));
            }
            it.next_method = .undefined;
        },
    }
    it.done = true;
    it.target = .undefined; // permanently exhausted; allow target collection
    return null;
}

pub fn iteratorClose(rt: *Runtime, iter: *Object, is_throw: bool) Error!void {
    const it = &iter.kind.iterator;
    if (it.done) return;
    const is_custom = it.kind == .custom;
    const target: Value = if (is_custom) it.target else Value.fromObject(iter);
    if (is_custom) {
        it.done = true;
        it.target = .undefined;
        it.next_method = .undefined;
    }

    const saved_ex = if (is_throw) rt.exception else null;
    const saved_tv = if (is_throw) rt.thrown_value else null;
    if (is_throw) {
        rt.exception = null;
        rt.thrown_value = null;
    }
    defer if (is_throw) {
        rt.exception = saved_ex;
        rt.thrown_value = saved_tv;
    };

    var root_buf = [_]Value{
        target,
        .undefined,
        .undefined,
        if (saved_ex) |ex| Value.fromString(ex.message) else .undefined,
        saved_tv orelse .undefined,
    };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const ret = object.get(rt, target, try object.named(rt, "return")) catch |e| {
        if (e == error.Thrown and is_throw) {
            rt.clearThrown();
            return;
        }
        return e;
    };
    if (ret.isUndefined() or ret.isNull()) return;
    if (!ret.isFunction()) {
        if (is_throw) return;
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator return method is not a function" }});
    }
    root_buf[1] = ret;
    const res = rt.callCallable(ret, target, &.{}) catch |e| {
        if (e == error.Thrown and is_throw) {
            rt.clearThrown();
            return;
        }
        return e;
    };
    root_buf[2] = res;
    if (!is_throw and !res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    }
}

/// `{ value, done }`.
pub fn iterResult(rt: *Runtime, value: Value, done: bool) Error!Value {
    const r = try realm(rt);
    const out = try rt.heap.newObject(r.object_prototype);
    try object.define(rt, out, try object.named(rt, "value"), value);
    try object.define(rt, out, try object.named(rt, "done"), Value.fromBool(done));
    return Value.fromObject(out);
}

/// One round of `yield*` (D67, spec 14.4.14): forwards `received` to the inner iterator's
/// next/throw/return per `mode`. Shared by both engines.
pub const YieldStarStep = struct {
    value: Value,
    kind: enum { yield, done, @"return" },
};

pub fn yieldStarStep(rt: *Runtime, iter: *Object, received: Value, mode: coroutine.ResumeMode) Error!YieldStarStep {
    if (iter.kind != .iterator) return rt.bug("yield* on a non-iterator");
    const it = &iter.kind.iterator;
    const inner: Value = if (it.kind == .custom) it.target else Value.fromObject(iter);
    var root_buf = [_]Value{ Value.fromObject(iter), received, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const method_fn: Value = switch (mode) {
        .next => if (it.kind == .custom) it.next_method else Value.fromNative(&iterator_next),
        .throw, .@"return" => try object.get(rt, inner, try object.named(rt, if (mode == .throw) "throw" else "return")),
    };
    root_buf[2] = method_fn;
    if (method_fn.isUndefined() or method_fn.isNull()) switch (mode) {
        .next => {},
        .throw => {
            try iteratorClose(rt, iter, false);
            return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method." }});
        },
        .@"return" => return .{ .value = received, .kind = .@"return" },
    };
    if (!method_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator method is not a function" }});
    const res = try rt.callCallable(method_fn, inner, &.{received});
    root_buf[3] = res;
    if (!res.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    if (!ops.toBoolean(try object.get(rt, res, try object.named(rt, "done")))) return .{ .value = res, .kind = .yield };
    const v = try object.get(rt, res, try object.named(rt, "value"));
    return .{ .value = v, .kind = if (mode == .@"return") .@"return" else .done };
}

// ---------------------------------------------------------------- Generators (M37, D67)

const generator_next: Native = .{ .name = "next", .length = 1, .call = generatorNext };
const generator_return: Native = .{ .name = "return", .length = 1, .call = generatorReturn };
const generator_throw: Native = .{ .name = "throw", .length = 1, .call = generatorThrow };

fn generatorResume(rt: *Runtime, this: Value, args: []const Value, mode: coroutine.ResumeMode, name: []const u8) Error!Value {
    if (!this.isObject() or this.asObject().kind != .generator or this.asObject().kind.generator.is_async) {
        return rt.throw(.TypeError, &.{ .{ .ascii = name }, .{ .ascii = " method called on incompatible receiver" } });
    }
    return coroutine.resumeGenerator(rt, this.asObject(), mode, arg(args, 0));
}

// ---------------------------------------------------------------- Async generators & iteration (M38, D68)

const async_iterator_self: Native = .{ .name = "[Symbol.asyncIterator]", .call = iteratorSelf };
const async_generator_next: Native = .{ .name = "next", .length = 1, .call = asyncGeneratorNext };
const async_generator_return: Native = .{ .name = "return", .length = 1, .call = asyncGeneratorReturn };
const async_generator_throw: Native = .{ .name = "throw", .length = 1, .call = asyncGeneratorThrow };
const async_from_sync_next: Native = .{ .name = "next", .length = 1, .call = asyncFromSyncNext };
const async_from_sync_return: Native = .{ .name = "return", .length = 1, .call = asyncFromSyncReturn };
const async_from_sync_throw: Native = .{ .name = "throw", .length = 1, .call = asyncFromSyncThrow };

fn asyncGeneratorNext(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return coroutine.asyncGeneratorRequest(rt, this, .next, arg(args, 0));
}

fn asyncGeneratorReturn(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return coroutine.asyncGeneratorRequest(rt, this, .@"return", arg(args, 0));
}

fn asyncGeneratorThrow(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return coroutine.asyncGeneratorRequest(rt, this, .throw, arg(args, 0));
}

/// GetMethod: `undefined` for a missing (undefined/null) method, TypeError if not callable.
fn getMethod(rt: *Runtime, v: Value, name: []const u8) Error!Value {
    const m = try object.get(rt, v, try object.named(rt, name));
    if (m.isUndefined() or m.isNull()) return .undefined;
    if (!m.isFunction()) return rt.throw(.TypeError, &.{ .{ .ascii = "iterator." }, .{ .ascii = name }, .{ .ascii = " is not a function" } });
    return m;
}

/// GetIterator(e, async) (D68): an iterator record (a `.custom` iterator holding the
/// async iterator and its cached `next`); a sync iterable is wrapped in an
/// async-from-sync iterator.
pub fn getAsyncIterator(rt: *Runtime, iterable: Value) Error!*Object {
    if (iterable.isUndefined() or iterable.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not async iterable" }});
    }
    const r = try realm(rt);
    var root_buf = [_]Value{ iterable, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const method_fn = try object.get(rt, iterable, .{ .symbol = r.sym_async_iterator });
    root_buf[1] = method_fn;
    if (method_fn.isUndefined() or method_fn.isNull()) {
        const sync = getIterator(rt, iterable) catch |e| {
            if (e != error.Thrown) return e;
            rt.clearThrown();
            return rt.throw(.TypeError, &.{.{ .ascii = "value is not async iterable" }});
        };
        root_buf[2] = Value.fromObject(sync);
        const afs = try rt.heap.newIterator(r.async_from_sync_iterator_prototype, root_buf[2], .async_from_sync);
        root_buf[3] = Value.fromObject(afs);
        return rt.heap.newCustomIterator(r.iterator_prototype, root_buf[3], Value.fromNative(&async_from_sync_next));
    }
    if (!method_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "value is not async iterable" }});
    const iter_val = try rt.callCallable(method_fn, iterable, &.{});
    root_buf[2] = iter_val;
    if (!iter_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Result of the Symbol.asyncIterator method is not an object" }});
    }
    const next_fn = try object.get(rt, iter_val, try object.named(rt, "next"));
    root_buf[3] = next_fn;
    return rt.heap.newCustomIterator(r.iterator_prototype, iter_val, next_fn);
}

/// `for await` step, before the await: `Call(next, iterator)`.
pub fn asyncIterNext(rt: *Runtime, rec: *Object) Error!Value {
    if (rec.kind != .iterator) return rt.bug("asyncIterNext on a non-iterator");
    const it = &rec.kind.iterator;
    if (!it.next_method.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
    return rt.callCallable(it.next_method, it.target, &.{});
}

/// `for await` step, after the await: the value, or null when done.
pub fn asyncIterValue(rt: *Runtime, res: Value) Error!?Value {
    if (!res.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    var root_buf = [_]Value{res};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (ops.toBoolean(try object.get(rt, res, try object.named(rt, "done")))) return null;
    return try object.get(rt, res, try object.named(rt, "value"));
}

/// AsyncIteratorClose, before the await: `return()`'s result to await, or null when there
/// is nothing to await. `is_throw`: the completion is a throw, so errors are swallowed
/// (the original exception wins). Closes `rec` at most once.
pub fn asyncIterCloseStart(rt: *Runtime, rec: *Object, is_throw: bool) Error!?Value {
    if (rec.kind != .iterator) return rt.bug("asyncIterClose on a non-iterator");
    const it = &rec.kind.iterator;
    if (it.done) return null;
    const target = it.target;
    it.done = true;
    it.target = .undefined;
    it.next_method = .undefined;
    var root_buf = [_]Value{ target, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const ret = getMethod(rt, target, "return") catch |e| {
        if (e != error.Thrown or !is_throw) return e;
        rt.clearThrown();
        return null;
    };
    if (ret.isUndefined()) return null;
    root_buf[1] = ret;
    return rt.callCallable(ret, target, &.{}) catch |e| {
        if (e != error.Thrown or !is_throw) return e;
        rt.clearThrown();
        return null;
    };
}

/// AsyncIteratorClose, after the await (normal completions only).
pub fn asyncIterCloseCheck(rt: *Runtime, v: Value) Error!void {
    if (!v.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
}

/// Async `yield*` round, before its await (D68): `value` is the inner call's result, or for
/// `missing_return` the received value (awaited, then returned), or for `missing_throw`
/// the inner `return()`'s result (awaited, checked, then a TypeError).
pub const AsyncYieldStar = struct {
    value: Value,
    kind: enum(u8) { call, call_return, missing_return, missing_throw },
};

pub fn asyncYieldStarCall(rt: *Runtime, rec: *Object, received: Value, mode: coroutine.ResumeMode) Error!AsyncYieldStar {
    if (rec.kind != .iterator) return rt.bug("async yield* on a non-iterator");
    const it = &rec.kind.iterator;
    const inner = it.target;
    var root_buf = [_]Value{ Value.fromObject(rec), received, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    switch (mode) {
        .next => {
            if (!it.next_method.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
            return .{ .value = try rt.callCallable(it.next_method, inner, &.{received}), .kind = .call };
        },
        .throw => {
            const thr = try getMethod(rt, inner, "throw");
            if (thr.isUndefined()) {
                const ret = try getMethod(rt, inner, "return");
                if (ret.isUndefined()) return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method" }});
                root_buf[2] = ret;
                return .{ .value = try rt.callCallable(ret, inner, &.{}), .kind = .missing_throw };
            }
            root_buf[2] = thr;
            return .{ .value = try rt.callCallable(thr, inner, &.{received}), .kind = .call };
        },
        .@"return" => {
            const ret = try getMethod(rt, inner, "return");
            if (ret.isUndefined()) return .{ .value = received, .kind = .missing_return };
            root_buf[2] = ret;
            return .{ .value = try rt.callCallable(ret, inner, &.{received}), .kind = .call_return };
        },
    }
}

/// Async `yield*` round, after its await: what the expression does next.
pub fn asyncYieldStarResult(rt: *Runtime, kind: @FieldType(AsyncYieldStar, "kind"), v: Value) Error!YieldStarStep {
    switch (kind) {
        .missing_return => return .{ .value = v, .kind = .@"return" },
        .missing_throw => {
            try asyncIterCloseCheck(rt, v);
            return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method" }});
        },
        .call, .call_return => {
            if (!v.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
            var root_buf = [_]Value{v};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            const done = ops.toBoolean(try object.get(rt, v, try object.named(rt, "done")));
            const value = try object.get(rt, v, try object.named(rt, "value"));
            if (!done) return .{ .value = value, .kind = .yield };
            return .{ .value = value, .kind = if (kind == .call_return) .@"return" else .done };
        },
    }
}

/// The sync iterator record inside an async-from-sync iterator (`this`).
fn asyncFromSyncRecord(this: Value) ?*Object {
    if (!this.isObject() or this.asObject().kind != .iterator) return null;
    const it = &this.asObject().kind.iterator;
    if (it.kind != .async_from_sync or !it.target.isObject()) return null;
    return it.target.asObject();
}

/// Runs `body` for an async-from-sync method: its abrupt completion rejects the promise
/// (IfAbruptRejectPromise).
fn asyncFromSync(rt: *Runtime, this: Value, args: []const Value, comptime mode: coroutine.ResumeMode) Error!Value {
    const r = try realm(rt);
    const p = try rt.heap.newPromise(r.promise_prototype);
    var root_buf = [_]Value{ Value.fromObject(p), this };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const rec = asyncFromSyncRecord(this) orelse return rt.bug("an async-from-sync method on a foreign receiver");
    asyncFromSyncStep(rt, p, rec, args, mode) catch |e| {
        if (e != error.Thrown) return e;
        try settlePromiseFromJob(rt, p, true, try rt.catchValue());
    };
    return root_buf[0];
}

fn asyncFromSyncStep(rt: *Runtime, p: *Object, rec: *Object, args: []const Value, comptime mode: coroutine.ResumeMode) Error!void {
    const it = &rec.kind.iterator;
    const sync_iter: Value = if (it.kind == .custom) it.target else Value.fromObject(rec);
    var root_buf = [_]Value{ Value.fromObject(rec), sync_iter, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const res: Value = switch (mode) {
        .next => blk: {
            const next_fn: Value = if (it.kind == .custom) it.next_method else Value.fromNative(&iterator_next);
            if (!next_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "iterator.next is not a function" }});
            break :blk try rt.callCallable(next_fn, sync_iter, args[0..@min(args.len, 1)]);
        },
        .@"return" => blk: {
            const ret = try getMethod(rt, sync_iter, "return");
            if (ret.isUndefined()) {
                root_buf[3] = try iterResult(rt, arg(args, 0), true);
                return resolvePromiseValue(rt, p, root_buf[3]);
            }
            root_buf[2] = ret;
            break :blk try rt.callCallable(ret, sync_iter, args[0..@min(args.len, 1)]);
        },
        .throw => blk: {
            const thr = try getMethod(rt, sync_iter, "throw");
            if (thr.isUndefined()) {
                try iteratorClose(rt, rec, false);
                return rt.throw(.TypeError, &.{.{ .ascii = "The iterator does not provide a 'throw' method" }});
            }
            root_buf[2] = thr;
            break :blk try rt.callCallable(thr, sync_iter, args[0..@min(args.len, 1)]);
        },
    };
    root_buf[3] = res;
    if (!res.isObjectLike()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    // AsyncFromSyncIteratorContinuation; a rejected value closes the sync iterator, except
    // for `return` (closeOnRejection false) or a done result.
    const done = ops.toBoolean(try object.get(rt, res, try object.named(rt, "done")));
    const value = try object.get(rt, res, try object.named(rt, "value"));
    root_buf[2] = value;
    const wrapper = try resolveToPromise(rt, value);
    root_buf[2] = wrapper;
    const on_ful = try rt.heap.newNativeClosure(if (done) @ptrCast(&asyncFromSyncUnwrapDone) else @ptrCast(&asyncFromSyncUnwrap), rec);
    root_buf[3] = Value.fromClosure(on_ful);
    const on_rej: Value = if (done or mode == .@"return") .undefined else Value.fromClosure(try rt.heap.newNativeClosure(@ptrCast(&asyncFromSyncCloseOnReject), rec));
    try performPromiseThenCap(rt, wrapper.asObject(), root_buf[3], on_rej, p);
}

fn asyncFromSyncUnwrap(rt: *Runtime, _: *Object, args: []const Value) Error!Value {
    return iterResult(rt, arg(args, 0), false);
}

fn asyncFromSyncUnwrapDone(rt: *Runtime, _: *Object, args: []const Value) Error!Value {
    return iterResult(rt, arg(args, 0), true);
}

fn asyncFromSyncCloseOnReject(rt: *Runtime, rec: *Object, args: []const Value) Error!Value {
    var root_buf = [_]Value{arg(args, 0)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    try iteratorClose(rt, rec, true);
    return rt.throwValue(root_buf[0]);
}

fn asyncFromSyncNext(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return asyncFromSync(rt, this, args, .next);
}

fn asyncFromSyncReturn(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return asyncFromSync(rt, this, args, .@"return");
}

fn asyncFromSyncThrow(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return asyncFromSync(rt, this, args, .throw);
}

fn generatorNext(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return generatorResume(rt, this, args, .next, "next");
}

fn generatorReturn(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return generatorResume(rt, this, args, .@"return", "return");
}

fn generatorThrow(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return generatorResume(rt, this, args, .throw, "throw");
}

fn iteratorNext(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .iterator) return unsupportedReceiver(rt, "next");
    const r = try realm(rt);
    const next_v = try iteratorNextVal(rt, this.asObject());
    const out = try rt.heap.newObject(r.object_prototype);
    try object.define(rt, out, try object.named(rt, "value"), next_v orelse .undefined);
    try object.define(rt, out, try object.named(rt, "done"), Value.fromBool(next_v == null));
    return Value.fromObject(out);
}

// ---------------------------------------------------------------- Errors (M25)

const error_to_string: Native = .{ .name = "toString", .call = errorToString };

fn initErrorProto(rt: *Runtime, proto: *Object, ns: *Object, name_ascii: []const u8, ctor: *const Native) Error!void {
    try immutableConstant(rt, ns, "prototype", Value.fromObject(proto));
    try constant(rt, proto, "constructor", Value.fromNative(ctor));
    try constant(rt, proto, "name", Value.fromString(try rt.heap.ascii(name_ascii)));
    try constant(rt, proto, "message", Value.fromString(try rt.heap.ascii("")));
}

fn errorToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Error.prototype.toString requires that 'this' be an Object" }});
    }
    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const name_val = try object.get(rt, this, try object.named(rt, "name"));
    const name_str = if (name_val.isUndefined()) try rt.heap.ascii("Error") else try toStringObj(rt, name_val);
    root_buf[1] = Value.fromString(name_str);

    const msg_val = try object.get(rt, this, try object.named(rt, "message"));
    const msg_str = if (msg_val.isUndefined()) try rt.heap.ascii("") else try toStringObj(rt, msg_val);
    root_buf[2] = Value.fromString(msg_str);

    if (name_str.units.len == 0) return Value.fromString(msg_str);
    if (msg_str.units.len == 0) return Value.fromString(name_str);
    return Value.fromString(try rt.heap.newString(&.{ .{ .utf16 = name_str.units }, .{ .ascii = ": " }, .{ .utf16 = msg_str.units } }));
}

fn buildError(rt: *Runtime, proto: *Object, msg_arg: Value, opts_arg: Value) Error!*Object {
    var root_buf = [_]Value{ msg_arg, opts_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(proto);
    err_obj.ordinary_tag = .@"error";
    root_buf[2] = Value.fromObject(err_obj);

    if (!msg_arg.isUndefined()) {
        const msg_str = try toStringObj(rt, msg_arg);
        root_buf[3] = Value.fromString(msg_str);
        try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[3], .enumerable = false });
    }
    if (opts_arg.isObject()) {
        const cause_key = try object.named(rt, "cause");
        if (try object.has(rt, cause_key, opts_arg)) {
            const cause_val = try object.get(rt, opts_arg, cause_key);
            root_buf[3] = cause_val;
            try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("cause"), .{ .value = cause_val, .enumerable = false });
        }
    }
    return err_obj;
}

pub fn makeEngineError(rt: *Runtime, name: rt_mod.ErrorName, msg: *const heap_mod.String) Error!Value {
    const r = try realm(rt);
    const proto = switch (name) {
        .ReferenceError => r.reference_error_prototype,
        .TypeError => r.type_error_prototype,
        .RangeError => r.range_error_prototype,
        .SyntaxError => r.syntax_error_prototype,
    };
    var root_buf = [_]Value{ Value.fromString(msg), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try rt.heap.newObject(proto);
    err_obj.ordinary_tag = .@"error";
    root_buf[1] = Value.fromObject(err_obj);
    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("message"), .{ .value = root_buf[0], .enumerable = false });
    return root_buf[1];
}

fn errorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return errorConstruct(rt, args);
}
fn errorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    return Value.fromObject(try buildError(rt, r.error_prototype, arg(args, 0), arg(args, 1)));
}

fn typeErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return typeErrorConstruct(rt, args);
}
fn typeErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    return Value.fromObject(try buildError(rt, r.type_error_prototype, arg(args, 0), arg(args, 1)));
}

fn rangeErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return rangeErrorConstruct(rt, args);
}
fn rangeErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    return Value.fromObject(try buildError(rt, r.range_error_prototype, arg(args, 0), arg(args, 1)));
}

fn syntaxErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return syntaxErrorConstruct(rt, args);
}
fn syntaxErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    return Value.fromObject(try buildError(rt, r.syntax_error_prototype, arg(args, 0), arg(args, 1)));
}

fn referenceErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return referenceErrorConstruct(rt, args);
}
fn referenceErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    return Value.fromObject(try buildError(rt, r.reference_error_prototype, arg(args, 0), arg(args, 1)));
}

fn evalErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return evalErrorConstruct(rt, args);
}
fn evalErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    return Value.fromObject(try buildError(rt, r.eval_error_prototype, arg(args, 0), arg(args, 1)));
}

fn uriErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return uriErrorConstruct(rt, args);
}
fn uriErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    return Value.fromObject(try buildError(rt, r.uri_error_prototype, arg(args, 0), arg(args, 1)));
}

fn aggregateErrorCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return aggregateErrorConstruct(rt, args);
}
fn aggregateErrorConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const r = try realm(rt);
    const errors_arg = arg(args, 0);
    const msg_arg = arg(args, 1);
    const opts_arg = arg(args, 2);

    var root_buf = [_]Value{ errors_arg, msg_arg, opts_arg, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const err_obj = try buildError(rt, r.aggregate_error_prototype, msg_arg, opts_arg);
    root_buf[3] = Value.fromObject(err_obj);

    const errors_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(errors_arr);

    const iter = try getIterator(rt, errors_arg);
    root_buf[5] = Value.fromObject(iter);

    while (try iteratorNextVal(rt, iter)) |elem| {
        root_buf[6] = elem;
        try rt.heap.appendElement(errors_arr, elem);
        root_buf[6] = .undefined;
    }

    try rt.heap.defineProperty(err_obj, try rt.heap.internAscii("errors"), .{ .value = root_buf[4], .enumerable = false });
    return root_buf[3];
}

// ---------------------------------------------------------------- RegExp (M30, D61)

const regexp_exec: Native = .{ .name = "exec", .call = regexpExec };
const regexp_test: Native = .{ .name = "test", .call = regexpTest };
const regexp_to_string: Native = .{ .name = "toString", .call = regexpToString };

fn thisRegExp(rt: *Runtime, this: Value, name: []const u8) Error!*Object {
    if (this.isObject() and this.asObject().kind == .regexp) return this.asObject();
    return unsupportedReceiver(rt, name);
}

fn failRuntimeRegExp(rt: *Runtime, err: regex.CompileError, rx_diag: regex.Diagnostic) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.SyntaxError => rt.throw(.SyntaxError, &.{.{ .ascii = rx_diag.message }}),
        error.TooComplex => rt.limit(rx_diag.limit),
        error.Unsupported => {
            const feat = if (rx_diag.feature) |f_name|
                std.meta.stringToEnum(Feature, f_name) orelse .syntax
            else
                .syntax;
            return rt.fail(feat);
        },
    };
}

pub fn createRegExp(rt: *Runtime, pattern_units: []const u16, flags_units: []const u16) Error!Value {
    var rx_diag: regex.Diagnostic = .{};
    const parsed_flags = regex.parseFlagsUtf16(flags_units, &rx_diag) catch |err| {
        return failRuntimeRegExp(rt, err, rx_diag);
    };
    var prog = regex.compileWithDepth(
        rt.heap.allocator(),
        pattern_units,
        parsed_flags.flags,
        rt.limits.max_nesting_depth,
        &rx_diag,
    ) catch |err| {
        if (err == error.OutOfMemory) return rt.heap.failed(error.OutOfMemory);
        return failRuntimeRegExp(rt, err, rx_diag);
    };
    var prog_owned = true;
    errdefer if (prog_owned) prog.deinit(rt.heap.allocator());

    const escaped = try regex.escapePattern(rt.gpa, pattern_units);
    defer rt.gpa.free(escaped);

    const r = try realm(rt);
    var root_buf = [_]Value{ .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const src_str = try rt.heap.newString(&.{.{ .utf16 = escaped }});
    root_buf[0] = Value.fromString(src_str);
    const flags_str = try rt.heap.ascii(parsed_flags.canonical());
    root_buf[1] = Value.fromString(flags_str);
    const obj = try rt.heap.newRegExp(r.regexp_prototype, prog, src_str, flags_str, parsed_flags.global);
    prog_owned = false;
    return Value.fromObject(obj);
}

pub fn newRegExpFromStrings(rt: *Runtime, pattern: *const heap_mod.String, flags: *const heap_mod.String) Error!Value {
    return createRegExp(rt, pattern.units, flags.units);
}

pub fn newRegExpFromLiteral(rt: *Runtime, pattern_units: []const u16, flags_ascii: []const u8) Error!Value {
    var flags_u16: [8]u16 = undefined;
    for (flags_ascii, 0..) |b, i| flags_u16[i] = b;
    return createRegExp(rt, pattern_units, flags_u16[0..flags_ascii.len]);
}

fn regexpBuild(rt: *Runtime, args: []const Value, is_new: bool) Error!Value {
    const p_arg = arg(args, 0);
    const f_arg = arg(args, 1);

    if (p_arg.isObject() and p_arg.asObject().kind == .regexp) {
        if (f_arg.isUndefined()) {
            if (!is_new) return p_arg;
            const re = p_arg.asObject().kind.regexp;
            const r = try realm(rt);
            var root_buf = [_]Value{p_arg};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);

            var cloned_prog = re.program.clone(rt.heap.allocator()) catch |e| return rt.heap.failed(e);
            errdefer cloned_prog.deinit(rt.heap.allocator());
            const obj = try rt.heap.newRegExp(r.regexp_prototype, cloned_prog, re.source, re.flags, re.global);
            return Value.fromObject(obj);
        }
        var root_buf = [_]Value{ p_arg, f_arg, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const flags_str = try toStringObj(rt, f_arg);
        root_buf[2] = Value.fromString(flags_str);
        return createRegExp(rt, p_arg.asObject().kind.regexp.source.units, flags_str.units);
    }

    var root_buf = [_]Value{ p_arg, f_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const pat_units: []const u16 = if (p_arg.isUndefined()) &.{} else blk: {
        const ps = try toStringObj(rt, p_arg);
        root_buf[2] = Value.fromString(ps);
        break :blk ps.units;
    };
    const flag_units: []const u16 = if (f_arg.isUndefined()) &.{} else blk: {
        const fs = try toStringObj(rt, f_arg);
        root_buf[3] = Value.fromString(fs);
        break :blk fs.units;
    };
    return createRegExp(rt, pat_units, flag_units);
}

fn regexpCall(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return regexpBuild(rt, args, false);
}

fn regexpConstruct(rt: *Runtime, args: []const Value) Error!Value {
    return regexpBuild(rt, args, true);
}

fn toLength(rt: *Runtime, v: Value) Error!f64 {
    const len = try toIntegerOrInfinity(rt, v);
    if (len <= 0) return 0;
    return @min(len, 9007199254740991.0);
}

fn runRegExpMatcher(
    rt: *Runtime,
    prog: *const regex.Program,
    input: []const u16,
    start: u32,
    captures: []?regex.Range,
) Error!bool {
    const initial_left: u64 = rt.max_steps -| rt.steps;
    var steps_left: u64 = initial_left;
    const matched = regex.exec(rt.heap.allocator(), prog, input, start, &steps_left, captures) catch |err| {
        const used = initial_left - steps_left;
        rt.steps += used;
        if (rt.exec_ctx.active) rt.exec_ctx.used = rt.steps;
        return switch (err) {
            error.StepLimit => {
                try rt.step();
                unreachable;
            },
            error.OutOfMemory => rt.heap.failed(error.OutOfMemory),
        };
    };
    const used = initial_left - steps_left;
    rt.steps += used;
    if (rt.exec_ctx.active) rt.exec_ctx.used = rt.steps;
    return matched;
}

/// Runs ECMAScript `RegExpBuiltinExec` into caller-allocated `captures` (`len == capture_count + 1`),
/// updating `rx_obj.lastIndex` when `global` or `sticky` is set.
fn regexpExecInto(
    rt: *Runtime,
    rx_obj: *Object,
    s: *const heap_mod.String,
    captures: []?regex.Range,
) Error!bool {
    var last_idx = try toLength(rt, rx_obj.kind.regexp.last_index);
    const re = rx_obj.kind.regexp;
    const global_or_sticky = re.global or re.program.flags.sticky;
    if (!global_or_sticky) {
        last_idx = 0;
    }
    if (last_idx > @as(f64, @floatFromInt(s.units.len))) {
        if (global_or_sticky) rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(0));
        return false;
    }
    const start: u32 = @intFromFloat(last_idx);
    const matched = try runRegExpMatcher(rt, &re.program, s.units, start, captures);
    if (!matched) {
        if (global_or_sticky) rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(0));
        return false;
    }
    if (global_or_sticky) {
        rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(@floatFromInt(captures[0].?.end)));
    }
    return true;
}

fn advanceStringIndex(units: []const u16, idx: usize, is_unicode: bool) usize {
    if (!is_unicode or idx + 1 >= units.len) return idx + 1;
    const first = units[idx];
    const second = units[idx + 1];
    if (first >= 0xD800 and first <= 0xDBFF and second >= 0xDC00 and second <= 0xDFFF) {
        return idx + 2;
    }
    return idx + 1;
}

fn buildMatchGroupsObject(
    rt: *Runtime,
    named_groups: []const regex.NamedGroup,
    s_units: []const u16,
    captures: []const ?regex.Range,
) Error!*Object {
    const groups_obj = try rt.heap.newObject(null);
    var root_buf = [_]Value{ Value.fromObject(groups_obj), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (named_groups) |ng| {
        const key_atom = try rt.heap.intern(ng.name);
        const val: Value = if (captures[ng.capture_index]) |rng| blk: {
            const sub = try rt.heap.newString(&.{.{ .utf16 = s_units[rng.start..rng.end] }});
            root_buf[1] = Value.fromString(sub);
            break :blk root_buf[1];
        } else .undefined;
        try object.define(rt, groups_obj, object.namedAtom(key_atom), val);
        root_buf[1] = .undefined;
    }
    return groups_obj;
}

fn makeIndexPair(rt: *Runtime, r: *const Realm, rng: regex.Range) Error!Value {
    const pair = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{Value.fromObject(pair)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    try rt.heap.appendElement(pair, Value.fromNumber(@floatFromInt(rng.start)));
    try rt.heap.appendElement(pair, Value.fromNumber(@floatFromInt(rng.end)));
    return Value.fromObject(pair);
}

fn buildMatchIndicesArray(
    rt: *Runtime,
    r: *const Realm,
    named_groups: []const regex.NamedGroup,
    captures: []const ?regex.Range,
) Error!*Object {
    const indices_arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ Value.fromObject(indices_arr), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    for (captures) |maybe_rng| {
        if (maybe_rng) |rng| {
            root_buf[1] = try makeIndexPair(rt, r, rng);
            try rt.heap.appendElement(indices_arr, root_buf[1]);
            root_buf[1] = .undefined;
        } else {
            try rt.heap.appendElement(indices_arr, .undefined);
        }
    }

    if (named_groups.len > 0) {
        const idx_groups = try rt.heap.newObject(null);
        root_buf[2] = Value.fromObject(idx_groups);
        for (named_groups) |ng| {
            const key_atom = try rt.heap.intern(ng.name);
            const val: Value = if (captures[ng.capture_index]) |rng| blk: {
                root_buf[1] = try makeIndexPair(rt, r, rng);
                break :blk root_buf[1];
            } else .undefined;
            try object.define(rt, idx_groups, object.namedAtom(key_atom), val);
            root_buf[1] = .undefined;
        }
        try object.define(rt, indices_arr, try object.named(rt, "groups"), root_buf[2]);
    } else {
        try object.define(rt, indices_arr, try object.named(rt, "groups"), .undefined);
    }
    return indices_arr;
}

fn regexpExecImpl(rt: *Runtime, rx_obj: *Object, s: *const heap_mod.String) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(rx_obj), Value.fromString(s), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const prog = &rx_obj.kind.regexp.program;
    const cap_len = @as(usize, prog.capture_count) + 1;
    const captures = try rt.gpa.alloc(?regex.Range, cap_len);
    defer rt.gpa.free(captures);

    if (!try regexpExecInto(rt, rx_obj, s, captures)) return .null;

    const r = try realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    root_buf[2] = Value.fromObject(arr);

    for (captures) |maybe_range| {
        if (maybe_range) |rng| {
            const sub = try rt.heap.newString(&.{.{ .utf16 = s.units[rng.start..rng.end] }});
            root_buf[3] = Value.fromString(sub);
            try rt.heap.appendElement(arr, root_buf[3]);
            root_buf[3] = .undefined;
        } else {
            try rt.heap.appendElement(arr, .undefined);
        }
    }
    try object.define(rt, arr, try object.named(rt, "index"), Value.fromNumber(@floatFromInt(captures[0].?.start)));
    try object.define(rt, arr, try object.named(rt, "input"), Value.fromString(s));

    const groups_val: Value = if (prog.named_groups.len > 0) blk: {
        const g = try buildMatchGroupsObject(rt, prog.named_groups, s.units, captures);
        root_buf[3] = Value.fromObject(g);
        break :blk root_buf[3];
    } else .undefined;
    try object.define(rt, arr, try object.named(rt, "groups"), groups_val);
    root_buf[3] = .undefined;

    if (prog.flags.has_indices) {
        const indices_arr = try buildMatchIndicesArray(rt, r, prog.named_groups, captures);
        root_buf[3] = Value.fromObject(indices_arr);
        try object.define(rt, arr, try object.named(rt, "indices"), root_buf[3]);
        root_buf[3] = .undefined;
    }
    return Value.fromObject(arr);
}

fn regexpExec(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const rx_obj = try thisRegExp(rt, this, "exec");
    var root_buf = [_]Value{ Value.fromObject(rx_obj), arg(args, 0) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try toStringObj(rt, root_buf[1]);
    return regexpExecImpl(rt, rx_obj, s);
}

fn regexpTest(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const rx_obj = try thisRegExp(rt, this, "test");
    var root_buf = [_]Value{ Value.fromObject(rx_obj), arg(args, 0), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try toStringObj(rt, root_buf[1]);
    root_buf[2] = Value.fromString(s);

    const cap_len = @as(usize, rx_obj.kind.regexp.program.capture_count) + 1;
    const captures = try rt.gpa.alloc(?regex.Range, cap_len);
    defer rt.gpa.free(captures);

    return Value.fromBool(try regexpExecInto(rt, rx_obj, s, captures));
}

const regexp_source_getter: Native = .{ .name = "get source", .call = regexpSourceGetter };
const regexp_flags_getter: Native = .{ .name = "get flags", .call = regexpFlagsGetter };
const regexp_has_indices_getter: Native = .{ .name = "get hasIndices", .call = regexpHasIndicesGetter };
const regexp_global_getter: Native = .{ .name = "get global", .call = regexpGlobalGetter };
const regexp_ignore_case_getter: Native = .{ .name = "get ignoreCase", .call = regexpIgnoreCaseGetter };
const regexp_multiline_getter: Native = .{ .name = "get multiline", .call = regexpMultilineGetter };
const regexp_dot_all_getter: Native = .{ .name = "get dotAll", .call = regexpDotAllGetter };
const regexp_unicode_getter: Native = .{ .name = "get unicode", .call = regexpUnicodeGetter };
const regexp_unicode_sets_getter: Native = .{ .name = "get unicodeSets", .call = regexpUnicodeSetsGetter };
const regexp_sticky_getter: Native = .{ .name = "get sticky", .call = regexpStickyGetter };

fn regexpSourceGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.source getter called on non-object" }});
    }
    const o = this.asObject();
    if (o.kind == .regexp) return Value.fromString(o.kind.regexp.source);
    if (o == (try realm(rt)).regexp_prototype) return Value.fromString(try rt.heap.ascii("(?:)"));
    return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.source getter called on incompatible receiver" }});
}

fn regexpFlagsGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() and !this.isClosure() and !this.isNative()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.flags getter called on non-object" }});
    }
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const spec = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "hasIndices", .ch = 'd' },
        .{ .name = "global", .ch = 'g' },
        .{ .name = "ignoreCase", .ch = 'i' },
        .{ .name = "multiline", .ch = 'm' },
        .{ .name = "dotAll", .ch = 's' },
        .{ .name = "unicode", .ch = 'u' },
        .{ .name = "unicodeSets", .ch = 'v' },
        .{ .name = "sticky", .ch = 'y' },
    };
    var buf: [8]u8 = undefined;
    var len: usize = 0;
    for (spec) |entry| {
        const v = try object.get(rt, this, try object.named(rt, entry.name));
        if (ops.toBoolean(v)) {
            buf[len] = entry.ch;
            len += 1;
        }
    }
    return Value.fromString(try rt.heap.ascii(buf[0..len]));
}

fn regexpFlagGetter(
    rt: *Runtime,
    this: Value,
    comptime field: enum { has_indices, global, ignore_case, multiline, dot_all, unicode, unicode_sets, sticky },
) Error!Value {
    if (!this.isObject()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype flag getter called on non-object" }});
    }
    const o = this.asObject();
    if (o.kind == .regexp) {
        const re = o.kind.regexp;
        return Value.fromBool(switch (field) {
            .has_indices => re.program.flags.has_indices,
            .global => re.global,
            .ignore_case => re.program.flags.ignore_case,
            .multiline => re.program.flags.multiline,
            .dot_all => re.program.flags.dot_all,
            .unicode => re.program.flags.unicode,
            .unicode_sets => re.program.flags.unicode_sets,
            .sticky => re.program.flags.sticky,
        });
    }
    if (o == (try realm(rt)).regexp_prototype) return .undefined;
    return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype flag getter called on incompatible receiver" }});
}

fn regexpHasIndicesGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .has_indices);
}

fn regexpGlobalGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .global);
}

fn regexpIgnoreCaseGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .ignore_case);
}

fn regexpMultilineGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .multiline);
}

fn regexpDotAllGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .dot_all);
}

fn regexpUnicodeGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .unicode);
}

fn regexpUnicodeSetsGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .unicode_sets);
}

fn regexpStickyGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return regexpFlagGetter(rt, this, .sticky);
}

fn regexpToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() and !this.isClosure() and !this.isNative()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype.toString requires that 'this' be an Object" }});
    }
    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const pattern = try toStringObj(rt, try object.get(rt, this, try object.named(rt, "source")));
    root_buf[1] = Value.fromString(pattern);
    const flags = try toStringObj(rt, try object.get(rt, this, try object.named(rt, "flags")));
    root_buf[2] = Value.fromString(flags);
    return Value.fromString(try rt.heap.newString(&.{
        .{ .ascii = "/" },
        .{ .utf16 = pattern.units },
        .{ .ascii = "/" },
        .{ .utf16 = flags.units },
    }));
}

const regexp_escape: Native = .{ .name = "escape", .length = 1, .call = regexpEscape };

fn appendHexEscape(rt: *Runtime, out: *std.ArrayList(u16), cp: u16) Error!void {
    const hex = "0123456789abcdef";
    if (cp < 0x100) {
        try appendUnits(rt, out, &.{ '\\', 'x', hex[(cp >> 4) & 0xF], hex[cp & 0xF] });
    } else {
        try appendUnits(rt, out, &.{ '\\', 'u', hex[(cp >> 12) & 0xF], hex[(cp >> 8) & 0xF], hex[(cp >> 4) & 0xF], hex[cp & 0xF] });
    }
}

fn regexpEscape(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.escape requires a string argument" }});
    }
    const units = v.asString().units;
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    var i: usize = 0;
    while (i < units.len) {
        const u = units[i];
        // Valid surrogate pair passes through verbatim
        if (u >= 0xD800 and u <= 0xDBFF and i + 1 < units.len) {
            const lo_u = units[i + 1];
            if (lo_u >= 0xDC00 and lo_u <= 0xDFFF) {
                try appendUnits(rt, &out, units[i .. i + 2]);
                i += 2;
                continue;
            }
        }
        // Lone surrogate -> \uHHHH
        if (u >= 0xD800 and u <= 0xDFFF) {
            try appendHexEscape(rt, &out, u);
            i += 1;
            continue;
        }
        // Leading ASCII letter or digit -> \xHH
        if (i == 0 and ((u >= '0' and u <= '9') or (u >= 'A' and u <= 'Z') or (u >= 'a' and u <= 'z'))) {
            try appendHexEscape(rt, &out, u);
            i += 1;
            continue;
        }
        switch (u) {
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => {
                try appendUnits(rt, &out, &.{ '\\', u });
            },
            0x09 => try appendUnits(rt, &out, &.{ '\\', 't' }),
            0x0A => try appendUnits(rt, &out, &.{ '\\', 'n' }),
            0x0B => try appendUnits(rt, &out, &.{ '\\', 'v' }),
            0x0C => try appendUnits(rt, &out, &.{ '\\', 'f' }),
            0x0D => try appendUnits(rt, &out, &.{ '\\', 'r' }),
            ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"', ' ' => {
                try appendHexEscape(rt, &out, u);
            },
            else => {
                if (isJsWhitespace(u)) {
                    try appendHexEscape(rt, &out, u);
                } else {
                    try appendUnits(rt, &out, &.{u});
                }
            },
        }
        i += 1;
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

const regexp_sym_match: Native = .{ .name = "[Symbol.match]", .length = 1, .call = regexpSymMatch };
const regexp_sym_replace: Native = .{ .name = "[Symbol.replace]", .length = 2, .call = regexpSymReplace };
const regexp_sym_search: Native = .{ .name = "[Symbol.search]", .length = 1, .call = regexpSymSearch };
const regexp_sym_split: Native = .{ .name = "[Symbol.split]", .length = 2, .call = regexpSymSplit };
const regexp_sym_match_all: Native = .{ .name = "[Symbol.matchAll]", .length = 1, .call = regexpSymMatchAll };

fn regExpExecGeneric(rt: *Runtime, rx: Value, s_val: Value) Error!Value {
    var root_buf = [_]Value{ rx, s_val, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const exec_fn = try object.get(rt, rx, try object.named(rt, "exec"));
    root_buf[2] = exec_fn;
    if (exec_fn.isFunction()) {
        const res = try rt.callCallable(exec_fn, rx, &.{s_val});
        if (!res.isObjectLike() and !res.isNull()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "RegExp exec method returned something other than an Object or null" }});
        }
        return res;
    }
    if (rx.isObject() and rx.asObject().kind == .regexp) {
        return regexpExecImpl(rt, rx.asObject(), s_val.asString());
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "RegExp exec called on incompatible receiver" }});
}

fn regexpSymMatch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.match] called on non-object" }});
    }
    var root_buf = [_]Value{ this, arg(args, 0), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[2] = s_val;

    const flags_val = try object.get(rt, this, try object.named(rt, "flags"));
    if (flags_val.isUndefined() or flags_val.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.match] flags is null or undefined" }});
    }
    const flags_s = try toStringObj(rt, flags_val);
    root_buf[3] = Value.fromString(flags_s);
    const is_global = std.mem.indexOfScalar(u16, flags_s.units, 'g') != null;

    if (!is_global) {
        return regExpExecGeneric(rt, this, s_val);
    }

    const full_unicode = std.mem.indexOfScalar(u16, flags_s.units, 'u') != null or
        std.mem.indexOfScalar(u16, flags_s.units, 'v') != null;
    try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(0));

    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(out);

    while (true) {
        const res = try regExpExecGeneric(rt, this, s_val);
        if (res.isNull()) {
            if (out.kind.array.items.len == 0) return .null;
            return Value.fromObject(out);
        }
        root_buf[5] = res;
        const m0 = try object.get(rt, res, .{ .index = 0 });
        const m_str = try toStringObj(rt, m0);
        root_buf[5] = Value.fromString(m_str);
        try rt.heap.appendElement(out, root_buf[5]);
        if (m_str.units.len == 0) {
            const li_val = try object.get(rt, this, try object.named(rt, "lastIndex"));
            const this_idx = try toLength(rt, li_val);
            const next_idx = advanceStringIndex(s.units, @intFromFloat(this_idx), full_unicode);
            try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(@floatFromInt(next_idx)));
        }
        root_buf[5] = .undefined;
    }
}

fn expandGenericReplacement(
    rt: *Runtime,
    out: *std.ArrayList(u16),
    matched_units: []const u16,
    s_units: []const u16,
    pos: usize,
    captures: []const Value,
    named_captures: Value,
    repl_units: []const u16,
) Error!void {
    const tail_pos = @min(pos + matched_units.len, s_units.len);
    const m = captures.len;
    var i: usize = 0;
    while (i < repl_units.len) {
        if (repl_units[i] == '$' and i + 1 < repl_units.len) {
            const next = repl_units[i + 1];
            switch (next) {
                '$' => {
                    try appendUnits(rt, out, &.{'$'});
                    i += 2;
                    continue;
                },
                '&' => {
                    try appendUnits(rt, out, matched_units);
                    i += 2;
                    continue;
                },
                '`' => {
                    try appendUnits(rt, out, s_units[0..@min(pos, s_units.len)]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try appendUnits(rt, out, s_units[tail_pos..]);
                    i += 2;
                    continue;
                },
                '0'...'9' => {
                    const d1: usize = next - '0';
                    if (i + 2 < repl_units.len and repl_units[i + 2] >= '0' and repl_units[i + 2] <= '9') {
                        const d2: usize = repl_units[i + 2] - '0';
                        const two = d1 * 10 + d2;
                        if (two >= 1 and two <= m) {
                            const cv = captures[two - 1];
                            if (cv.isString()) try appendUnits(rt, out, cv.asString().units);
                            i += 3;
                            continue;
                        }
                    }
                    if (d1 >= 1 and d1 <= m) {
                        const cv = captures[d1 - 1];
                        if (cv.isString()) try appendUnits(rt, out, cv.asString().units);
                        i += 2;
                        continue;
                    }
                },
                '<' => {
                    if (!named_captures.isUndefined()) {
                        if (std.mem.indexOfScalarPos(u16, repl_units, i + 2, '>')) |gt| {
                            const gname = repl_units[i + 2 .. gt];
                            const k = try object.keyUnits(rt, gname);
                            const cv = try object.get(rt, named_captures, k);
                            if (!cv.isUndefined()) {
                                const cs = try toStringObj(rt, cv);
                                try appendUnits(rt, out, cs.units);
                            }
                            i = gt + 1;
                            continue;
                        }
                    }
                },
                else => {},
            }
        }
        try appendUnits(rt, out, repl_units[i .. i + 1]);
        i += 1;
    }
}

fn regexpSymReplace(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.replace] called on non-object" }});
    }
    var root_buf = [_]Value{ this, arg(args, 0), arg(args, 1), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[3] = s_val;
    const repl_arg = root_buf[2];
    const functional = repl_arg.isFunction();
    const repl_str: ?*const heap_mod.String = if (!functional) blk: {
        const rs = try toStringObj(rt, repl_arg);
        root_buf[4] = Value.fromString(rs);
        break :blk rs;
    } else null;

    const flags_val = try object.get(rt, this, try object.named(rt, "flags"));
    if (flags_val.isUndefined() or flags_val.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.replace] flags is null or undefined" }});
    }
    const flags_s = try toStringObj(rt, flags_val);
    root_buf[5] = Value.fromString(flags_s);
    const is_global = std.mem.indexOfScalar(u16, flags_s.units, 'g') != null;
    const full_unicode = std.mem.indexOfScalar(u16, flags_s.units, 'u') != null or
        std.mem.indexOfScalar(u16, flags_s.units, 'v') != null;

    if (is_global) {
        try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(0));
    }

    const r = try realm(rt);
    const results = try rt.heap.newArray(r.array_prototype);
    root_buf[6] = Value.fromObject(results);

    while (true) {
        const res = try regExpExecGeneric(rt, this, s_val);
        if (res.isNull()) break;
        try rt.heap.appendElement(results, res);
        if (!is_global) break;
        const m0 = try object.get(rt, res, .{ .index = 0 });
        const m_str = try toStringObj(rt, m0);
        if (m_str.units.len == 0) {
            const li_val = try object.get(rt, this, try object.named(rt, "lastIndex"));
            const this_idx = try toLength(rt, li_val);
            const next_idx = advanceStringIndex(s.units, @intFromFloat(this_idx), full_unicode);
            try object.setStrict(rt, this, try object.named(rt, "lastIndex"), Value.fromNumber(@floatFromInt(next_idx)));
        }
    }

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    var next_src_pos: usize = 0;

    for (results.kind.array.items) |res| {
        const res_len_f = try toLength(rt, try object.get(rt, res, try object.named(rt, "length")));
        const n_captures: usize = if (res_len_f > 1.0) @intFromFloat(res_len_f - 1.0) else 0;
        const matched = try toStringObj(rt, try object.get(rt, res, .{ .index = 0 }));
        const pos_raw = try toIntegerOrInfinity(rt, try object.get(rt, res, try object.named(rt, "index")));
        const pos: usize = @intFromFloat(@min(@max(pos_raw, 0.0), @as(f64, @floatFromInt(s.units.len))));

        const cap_vals = try rt.gpa.alloc(Value, n_captures);
        defer rt.gpa.free(cap_vals);
        @memset(cap_vals, .undefined);
        var cap_roots: rt_mod.ValueRoots = .{ .values = cap_vals };
        try cap_roots.register(rt);
        defer cap_roots.unregister(rt);

        var cap_i: usize = 0;
        while (cap_i < n_captures) : (cap_i += 1) {
            const cv = try object.get(rt, res, .{ .index = @intCast(cap_i + 1) });
            if (!cv.isUndefined()) {
                cap_vals[cap_i] = Value.fromString(try toStringObj(rt, cv));
            }
        }
        const named_captures = try object.get(rt, res, try object.named(rt, "groups"));
        var extra_roots_buf = [_]Value{ Value.fromString(matched), named_captures, .undefined };
        var extra_roots: rt_mod.ValueRoots = .{ .values = &extra_roots_buf };
        try extra_roots.register(rt);
        defer extra_roots.unregister(rt);

        var replacement_s: *const heap_mod.String = undefined;
        var use_expanded = false;
        if (functional) {
            const has_named = !named_captures.isUndefined();
            const argc = 1 + n_captures + 2 + @as(usize, if (has_named) 1 else 0);
            const cb_args = try rt.gpa.alloc(Value, argc);
            defer rt.gpa.free(cb_args);
            cb_args[0] = Value.fromString(matched);
            @memcpy(cb_args[1 .. 1 + n_captures], cap_vals);
            cb_args[1 + n_captures] = Value.fromNumber(@floatFromInt(pos));
            cb_args[2 + n_captures] = s_val;
            if (has_named) cb_args[3 + n_captures] = named_captures;
            const call_res = try rt.callCallable(repl_arg, .undefined, cb_args);
            replacement_s = try toStringObj(rt, call_res);
            extra_roots_buf[2] = Value.fromString(replacement_s);
        } else {
            if (!named_captures.isUndefined()) {
                extra_roots_buf[1] = try toObjectReceiver(rt, named_captures);
            }
            use_expanded = true;
        }
        if (pos >= next_src_pos) {
            try appendUnits(rt, &out, s.units[next_src_pos..pos]);
            if (use_expanded) {
                try expandGenericReplacement(rt, &out, matched.units, s.units, pos, cap_vals, extra_roots_buf[1], repl_str.?.units);
            } else {
                try appendUnits(rt, &out, replacement_s.units);
            }
            next_src_pos = @min(pos + matched.units.len, s.units.len);
        }
    }
    if (next_src_pos < s.units.len) {
        try appendUnits(rt, &out, s.units[next_src_pos..]);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn regexpSymSearch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.search] called on non-object" }});
    }
    var root_buf = [_]Value{ this, arg(args, 0), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[2] = s_val;

    const li_key = try object.named(rt, "lastIndex");
    const prev_li = try object.get(rt, this, li_key);
    root_buf[3] = prev_li;
    if (!sameValue(prev_li, Value.fromNumber(0))) {
        try object.setStrict(rt, this, li_key, Value.fromNumber(0));
    }
    const res = try regExpExecGeneric(rt, this, s_val);
    root_buf[4] = res;
    const cur_li = try object.get(rt, this, li_key);
    if (!sameValue(cur_li, prev_li)) {
        try object.setStrict(rt, this, li_key, prev_li);
    }
    if (res.isNull()) return Value.fromNumber(-1);
    return object.get(rt, res, try object.named(rt, "index"));
}

fn regexpSymSplit(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.split] called on non-object" }});
    }
    var root_buf = [_]Value{ this, arg(args, 0), arg(args, 1), .undefined, .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try toStringObj(rt, root_buf[1]);
    const s_val = Value.fromString(s);
    root_buf[3] = s_val;

    const ctor = try speciesConstructor(rt, this, Value.fromNative(&regexp_global));
    root_buf[4] = ctor;

    const flags_val = try object.get(rt, this, try object.named(rt, "flags"));
    const flags_s = try toStringObj(rt, flags_val);
    root_buf[5] = Value.fromString(flags_s);

    const unicode_matching = std.mem.indexOfScalar(u16, flags_s.units, 'u') != null or
        std.mem.indexOfScalar(u16, flags_s.units, 'v') != null;
    const new_flags: Value = if (std.mem.indexOfScalar(u16, flags_s.units, 'y') != null)
        Value.fromString(flags_s)
    else
        Value.fromString(try rt.heap.newString(&.{ .{ .utf16 = flags_s.units }, .{ .ascii = "y" } }));
    root_buf[5] = new_flags;

    const splitter = try constructValue(rt, ctor, &.{ this, new_flags });
    root_buf[6] = splitter;

    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[7] = Value.fromObject(out);

    const lim: u32 = if (root_buf[2].isUndefined()) std.math.maxInt(u32) else ops.toUint32(try ops.toNumber(rt, root_buf[2]));
    if (lim == 0) return Value.fromObject(out);

    const size = s.units.len;
    if (size == 0) {
        const z = try regExpExecGeneric(rt, splitter, s_val);
        if (!z.isNull()) return Value.fromObject(out);
        try rt.heap.appendElement(out, s_val);
        return Value.fromObject(out);
    }

    const li_key = try object.named(rt, "lastIndex");
    var p: usize = 0;
    var q: usize = 0;
    while (q < size) {
        try object.setStrict(rt, splitter, li_key, Value.fromNumber(@floatFromInt(q)));
        const z = try regExpExecGeneric(rt, splitter, s_val);
        if (z.isNull()) {
            q = advanceStringIndex(s.units, q, unicode_matching);
            continue;
        }
        var z_roots_buf = [_]Value{ z, .undefined };
        var z_roots: rt_mod.ValueRoots = .{ .values = &z_roots_buf };
        try z_roots.register(rt);
        defer z_roots.unregister(rt);

        const e_f = try toLength(rt, try object.get(rt, splitter, li_key));
        const e: usize = @min(@as(usize, @intFromFloat(e_f)), size);
        if (e == p) {
            q = advanceStringIndex(s.units, q, unicode_matching);
            continue;
        }
        const sub = try rt.heap.newString(&.{.{ .utf16 = s.units[p..q] }});
        z_roots_buf[1] = Value.fromString(sub);
        try rt.heap.appendElement(out, z_roots_buf[1]);
        if (out.kind.array.items.len == lim) return Value.fromObject(out);
        p = e;
        const z_len_f = try toLength(rt, try object.get(rt, z, try object.named(rt, "length")));
        const n_caps: usize = if (z_len_f > 1.0) @intFromFloat(z_len_f - 1.0) else 0;
        var i: usize = 1;
        while (i <= n_caps) : (i += 1) {
            const cap = try object.get(rt, z, .{ .index = @intCast(i) });
            z_roots_buf[1] = cap;
            try rt.heap.appendElement(out, cap);
            if (out.kind.array.items.len == lim) return Value.fromObject(out);
        }
        q = p;
    }
    const tail = try rt.heap.newString(&.{.{ .utf16 = s.units[p..size] }});
    try rt.heap.appendElement(out, Value.fromString(tail));
    return Value.fromObject(out);
}

fn regexpSymMatchAll(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObject() and !this.isClosure() and !this.isNative()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.matchAll] called on non-object" }});
    }
    if (this.isObject() and this.asObject().kind == .regexp) {
        var root_buf = [_]Value{ this, arg(args, 0), .undefined, .undefined };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);

        const s = try toStringObj(rt, root_buf[1]);
        root_buf[2] = Value.fromString(s);

        const orig = this.asObject().kind.regexp;
        const cloned = try newRegExpFromStrings(rt, orig.source, orig.flags);
        root_buf[3] = cloned;
        const last_idx = try toLength(rt, orig.last_index);
        rt.heap.storeRegExpLastIndex(cloned.asObject(), Value.fromNumber(last_idx));
        const r = try realm(rt);
        return Value.fromObject(try rt.heap.newMatchAllIterator(r.iterator_prototype, cloned.asObject(), s));
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "RegExp.prototype[Symbol.matchAll] requires a RegExp receiver" }});
}

fn coerceToRegExp(rt: *Runtime, v: Value) Error!*Object {
    if (v.isObject() and v.asObject().kind == .regexp) return v.asObject();
    const created = try regexpBuild(rt, &.{v}, true);
    return created.asObject();
}

fn stringMatch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.match called on null or undefined" }});
    }
    const rx_arg = arg(args, 0);
    if (!rx_arg.isUndefined() and !rx_arg.isNull()) {
        const r = try realm(rt);
        if (try object.getMethod(rt, rx_arg, .{ .symbol = r.sym_match })) |matcher| {
            return rt.callCallable(matcher, rx_arg, &.{this});
        }
    }
    const s = try toStringObj(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), rx_arg, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const rx_obj = try coerceToRegExp(rt, root_buf[1]);
    root_buf[2] = Value.fromObject(rx_obj);

    if (!rx_obj.kind.regexp.global) {
        return regexpExecImpl(rt, rx_obj, s);
    }

    rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(0));
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[3] = Value.fromObject(out);

    const cap_len = @as(usize, rx_obj.kind.regexp.program.capture_count) + 1;
    const captures = try rt.gpa.alloc(?regex.Range, cap_len);
    defer rt.gpa.free(captures);

    const is_unicode = rx_obj.kind.regexp.program.flags.isUnicodeMode();
    while (try regexpExecInto(rt, rx_obj, s, captures)) {
        const rng = captures[0].?;
        const sub = try rt.heap.newString(&.{.{ .utf16 = s.units[rng.start..rng.end] }});
        root_buf[4] = Value.fromString(sub);
        try rt.heap.appendElement(out, root_buf[4]);
        root_buf[4] = .undefined;
        if (rng.start == rng.end) {
            const this_idx = try toLength(rt, rx_obj.kind.regexp.last_index);
            const next_idx = advanceStringIndex(s.units, @intFromFloat(this_idx), is_unicode);
            rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(@floatFromInt(next_idx)));
        }
    }
    if (out.kind.array.items.len == 0) return .null;
    return Value.fromObject(out);
}

fn stringMatchAll(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.matchAll called on null or undefined" }});
    }
    const rx_arg = arg(args, 0);
    if (!rx_arg.isUndefined() and !rx_arg.isNull()) {
        if (rx_arg.isObject() and rx_arg.asObject().kind == .regexp) {
            const flags_val = try object.get(rt, rx_arg, try object.named(rt, "flags"));
            if (flags_val.isUndefined() or flags_val.isNull()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.matchAll called with a non-global RegExp argument" }});
            }
            const flags_s = try toStringObj(rt, flags_val);
            if (std.mem.indexOfScalar(u16, flags_s.units, 'g') == null) {
                return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.matchAll called with a non-global RegExp argument" }});
            }
        }
        const r = try realm(rt);
        if (try object.getMethod(rt, rx_arg, .{ .symbol = r.sym_match_all })) |matcher| {
            return rt.callCallable(matcher, rx_arg, &.{this});
        }
    }
    var root_buf = [_]Value{ this, rx_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const s = try toStringObj(rt, this);
    root_buf[2] = Value.fromString(s);

    const g_str: Value = Value.fromString(try rt.heap.ascii("g"));
    const created = try regexpBuild(rt, &.{ rx_arg, g_str }, true);
    root_buf[3] = created;

    const r = try realm(rt);
    return Value.fromObject(try rt.heap.newMatchAllIterator(r.iterator_prototype, created.asObject(), s));
}

fn stringSearch(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "String.prototype.search called on null or undefined" }});
    }
    const rx_arg = arg(args, 0);
    if (!rx_arg.isUndefined() and !rx_arg.isNull()) {
        const r = try realm(rt);
        if (try object.getMethod(rt, rx_arg, .{ .symbol = r.sym_search })) |searcher| {
            return rt.callCallable(searcher, rx_arg, &.{this});
        }
    }
    const s = try toStringObj(rt, this);
    var root_buf = [_]Value{ Value.fromString(s), rx_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const rx_obj = try coerceToRegExp(rt, root_buf[1]);
    root_buf[2] = Value.fromObject(rx_obj);

    const cap_len = @as(usize, rx_obj.kind.regexp.program.capture_count) + 1;
    const captures = try rt.gpa.alloc(?regex.Range, cap_len);
    defer rt.gpa.free(captures);

    if (try runRegExpMatcher(rt, &rx_obj.kind.regexp.program, s.units, 0, captures)) {
        return Value.fromNumber(@floatFromInt(captures[0].?.start));
    }
    return Value.fromNumber(-1);
}

fn expandRegExpReplacement(
    rt: *Runtime,
    out: *std.ArrayList(u16),
    s_units: []const u16,
    captures: []const ?regex.Range,
    named_groups: []const regex.NamedGroup,
    repl_units: []const u16,
) Error!void {
    const full = captures[0].?;
    const m = captures.len - 1;
    var i: usize = 0;
    while (i < repl_units.len) {
        if (repl_units[i] == '$' and i + 1 < repl_units.len) {
            const next = repl_units[i + 1];
            switch (next) {
                '$' => {
                    try appendUnits(rt, out, &.{'$'});
                    i += 2;
                    continue;
                },
                '&' => {
                    try appendUnits(rt, out, s_units[full.start..full.end]);
                    i += 2;
                    continue;
                },
                '`' => {
                    try appendUnits(rt, out, s_units[0..full.start]);
                    i += 2;
                    continue;
                },
                '\'' => {
                    try appendUnits(rt, out, s_units[full.end..]);
                    i += 2;
                    continue;
                },
                '<' => {
                    if (named_groups.len > 0) {
                        if (std.mem.indexOfScalarPos(u16, repl_units, i + 2, '>')) |close_idx| {
                            const gname = repl_units[i + 2 .. close_idx];
                            for (named_groups) |ng| {
                                if (std.mem.eql(u16, ng.name, gname)) {
                                    if (captures[ng.capture_index]) |rng| {
                                        try appendUnits(rt, out, s_units[rng.start..rng.end]);
                                    }
                                    break;
                                }
                            }
                            i = close_idx + 1;
                            continue;
                        }
                    }
                },
                '0'...'9' => {
                    const d1: usize = next - '0';
                    if (i + 2 < repl_units.len and repl_units[i + 2] >= '0' and repl_units[i + 2] <= '9') {
                        const d2: usize = repl_units[i + 2] - '0';
                        const nn = d1 * 10 + d2;
                        if (nn >= 1 and nn <= m) {
                            if (captures[nn]) |rng| try appendUnits(rt, out, s_units[rng.start..rng.end]);
                            i += 3;
                            continue;
                        }
                    }
                    if (d1 >= 1 and d1 <= m) {
                        if (captures[d1]) |rng| try appendUnits(rt, out, s_units[rng.start..rng.end]);
                        i += 2;
                        continue;
                    }
                },
                else => {},
            }
        }
        try appendUnits(rt, out, repl_units[i .. i + 1]);
        i += 1;
    }
}

fn stringReplaceRegExp(
    rt: *Runtime,
    this: Value,
    s: *const heap_mod.String,
    rx_obj: *Object,
    repl_arg: Value,
) Error!Value {
    const is_func = repl_arg.isNative() or repl_arg.isClosure();
    var root_buf = [_]Value{ this, Value.fromObject(rx_obj), repl_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const repl_str: ?*const heap_mod.String = if (!is_func) blk: {
        const rs = try toStringObj(rt, repl_arg);
        root_buf[3] = Value.fromString(rs);
        break :blk rs;
    } else null;

    const named_groups = rx_obj.kind.regexp.program.named_groups;
    const is_unicode = rx_obj.kind.regexp.program.flags.isUnicodeMode();
    const is_global = rx_obj.kind.regexp.global;
    if (is_global) {
        rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(0));
    }

    const cap_len = @as(usize, rx_obj.kind.regexp.program.capture_count) + 1;
    var all_matches: std.ArrayList([]?regex.Range) = .empty;
    defer {
        for (all_matches.items) |m_slice| rt.gpa.free(m_slice);
        all_matches.deinit(rt.gpa);
    }

    while (true) {
        const caps = try rt.gpa.alloc(?regex.Range, cap_len);
        errdefer rt.gpa.free(caps);
        if (!try regexpExecInto(rt, rx_obj, s, caps)) {
            rt.gpa.free(caps);
            break;
        }
        try all_matches.append(rt.gpa, caps);
        if (!is_global) break;
        const rng = caps[0].?;
        if (rng.start == rng.end) {
            const this_idx = try toLength(rt, rx_obj.kind.regexp.last_index);
            const next_idx = advanceStringIndex(s.units, @intFromFloat(this_idx), is_unicode);
            rt.heap.storeRegExpLastIndex(rx_obj, Value.fromNumber(@floatFromInt(next_idx)));
        }
    }

    if (all_matches.items.len == 0) return this;

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);

    const has_named = named_groups.len > 0;
    const cb_arg_count = cap_len + 2 + @as(usize, if (has_named) 1 else 0);
    const cb_args: []Value = if (is_func) try rt.gpa.alloc(Value, cb_arg_count) else &.{};
    defer if (is_func) rt.gpa.free(cb_args);
    @memset(cb_args, .undefined);
    var cb_roots: rt_mod.ValueRoots = .{ .values = cb_args };
    if (is_func) try cb_roots.register(rt);
    defer if (is_func) cb_roots.unregister(rt);

    var next_src_pos: usize = 0;
    for (all_matches.items) |caps| {
        const full = caps[0].?;
        if (full.start < next_src_pos) continue;
        try appendUnits(rt, &out, s.units[next_src_pos..full.start]);
        if (is_func) {
            @memset(cb_args, .undefined);
            for (caps, 0..) |maybe_rng, idx| {
                if (maybe_rng) |r| {
                    cb_args[idx] = Value.fromString(try rt.heap.newString(&.{.{ .utf16 = s.units[r.start..r.end] }}));
                } else {
                    cb_args[idx] = .undefined;
                }
            }
            cb_args[cap_len] = Value.fromNumber(@floatFromInt(full.start));
            cb_args[cap_len + 1] = this;
            if (has_named) {
                cb_args[cap_len + 2] = Value.fromObject(try buildMatchGroupsObject(rt, named_groups, s.units, caps));
            }
            const res = try rt.callCallable(repl_arg, .undefined, cb_args);
            root_buf[4] = res;
            const rs = try toStringObj(rt, res);
            root_buf[4] = Value.fromString(rs);
            try appendUnits(rt, &out, rs.units);
        } else {
            try expandRegExpReplacement(rt, &out, s.units, caps, named_groups, repl_str.?.units);
        }
        next_src_pos = full.end;
    }
    try appendUnits(rt, &out, s.units[next_src_pos..]);
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn stringSplitRegExp(
    rt: *Runtime,
    this: Value,
    s: *const heap_mod.String,
    rx_obj: *Object,
    limit_arg: Value,
) Error!Value {
    var root_buf = [_]Value{ this, Value.fromObject(rx_obj), limit_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const lim: u32 = if (limit_arg.isUndefined()) std.math.maxInt(u32) else ops.toUint32(try ops.toNumber(rt, limit_arg));
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    root_buf[3] = Value.fromObject(out);
    if (lim == 0) return Value.fromObject(out);

    var p_split = rx_obj.kind.regexp.program;
    p_split.flags.sticky = false;
    const cap_len = @as(usize, p_split.capture_count) + 1;
    const captures = try rt.gpa.alloc(?regex.Range, cap_len);
    defer rt.gpa.free(captures);

    if (s.units.len == 0) {
        if (!try runRegExpMatcher(rt, &p_split, s.units, 0, captures)) {
            try rt.heap.appendElement(out, this);
        }
        return Value.fromObject(out);
    }

    const is_unicode = p_split.flags.isUnicodeMode();
    const size: u32 = @intCast(s.units.len);
    var p: u32 = 0;
    var q: u32 = 0;
    while (q < size) {
        if (!try runRegExpMatcher(rt, &p_split, s.units, q, captures)) break;
        const full = captures[0].?;
        if (full.end == p) {
            q = @intCast(advanceStringIndex(s.units, q, is_unicode));
            continue;
        }
        const seg = try rt.heap.newString(&.{.{ .utf16 = s.units[p..full.start] }});
        root_buf[4] = Value.fromString(seg);
        try rt.heap.appendElement(out, root_buf[4]);
        root_buf[4] = .undefined;
        if (out.kind.array.items.len == lim) return Value.fromObject(out);

        for (captures[1..]) |maybe_cap| {
            if (maybe_cap) |rng| {
                const cap_str = try rt.heap.newString(&.{.{ .utf16 = s.units[rng.start..rng.end] }});
                root_buf[4] = Value.fromString(cap_str);
                try rt.heap.appendElement(out, root_buf[4]);
                root_buf[4] = .undefined;
            } else {
                try rt.heap.appendElement(out, .undefined);
            }
            if (out.kind.array.items.len == lim) return Value.fromObject(out);
        }
        p = full.end;
        q = p;
    }

    const tail = try rt.heap.newString(&.{.{ .utf16 = s.units[p..] }});
    root_buf[4] = Value.fromString(tail);
    try rt.heap.appendElement(out, root_buf[4]);
    return Value.fromObject(out);
}

pub fn getTemplateObjectFromConsts(
    rt: *Runtime,
    key: usize,
    cooked: []const u32,
    raw: []const u32,
    consts: []const Value,
) Error!Value {
    if (rt.template_cache.get(key)) |cached| return Value.fromObject(cached);
    const r = try realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ Value.fromObject(arr), .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const raw_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[1] = Value.fromObject(raw_arr);

    for (cooked) |k| {
        const v: Value = if (k == std.math.maxInt(u32)) .undefined else consts[k];
        try rt.heap.appendElement(arr, v);
    }
    for (raw) |k| {
        try rt.heap.appendElement(raw_arr, consts[k]);
    }
    try object.define(rt, arr, try object.named(rt, "raw"), root_buf[1]);
    try rt.template_cache.put(rt.gpa, key, arr);
    return Value.fromObject(arr);
}

pub fn getTemplateObjectFromUnits(
    rt: *Runtime,
    key: usize,
    cooked: []const ?[]const u16,
    raw: []const []const u16,
) Error!Value {
    if (rt.template_cache.get(key)) |cached| return Value.fromObject(cached);
    const r = try realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ Value.fromObject(arr), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const raw_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[1] = Value.fromObject(raw_arr);

    for (cooked) |maybe_u| {
        if (maybe_u) |u| {
            const s = try rt.heap.newString(&.{.{ .utf16 = u }});
            root_buf[2] = Value.fromString(s);
            try rt.heap.appendElement(arr, root_buf[2]);
            root_buf[2] = .undefined;
        } else {
            try rt.heap.appendElement(arr, .undefined);
        }
    }
    for (raw) |u| {
        const s = try rt.heap.newString(&.{.{ .utf16 = u }});
        root_buf[2] = Value.fromString(s);
        try rt.heap.appendElement(raw_arr, root_buf[2]);
        root_buf[2] = .undefined;
    }
    try object.define(rt, arr, try object.named(rt, "raw"), root_buf[1]);
    try rt.template_cache.put(rt.gpa, key, arr);
    return Value.fromObject(arr);
}

// ---------------------------------------------------------------- ArrayBuffer, TypedArray & DataView (M43, D73)

pub const array_buffer_global: Native = .{
    .name = "ArrayBuffer",
    .length = 1,
    .call = arrayBufferWithoutNew,
    .construct = arrayBufferConstruct,
    .namespace = .array_buffer,
};

pub const data_view_global: Native = .{
    .name = "DataView",
    .length = 1,
    .call = dataViewWithoutNew,
    .construct = dataViewConstruct,
    .namespace = .data_view,
};

pub const typed_array_global: Native = .{
    .name = "TypedArray",
    .length = 0,
    .call = typedArrayAbstractCall,
    .construct = typedArrayAbstractConstruct,
    .namespace = .typed_array,
};

pub const typed_array_ctors: [11]Native = .{
    .{ .name = "Int8Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructInt8, .namespace = .int8_array },
    .{ .name = "Uint8Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructUint8, .namespace = .uint8_array },
    .{ .name = "Uint8ClampedArray", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructUint8Clamped, .namespace = .uint8_clamped_array },
    .{ .name = "Int16Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructInt16, .namespace = .int16_array },
    .{ .name = "Uint16Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructUint16, .namespace = .uint16_array },
    .{ .name = "Int32Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructInt32, .namespace = .int32_array },
    .{ .name = "Uint32Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructUint32, .namespace = .uint32_array },
    .{ .name = "Float32Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructFloat32, .namespace = .float32_array },
    .{ .name = "Float64Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructFloat64, .namespace = .float64_array },
    .{ .name = "BigInt64Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructBigInt64, .namespace = .bigint64_array },
    .{ .name = "BigUint64Array", .length = 3, .call = typedArrayWithoutNew, .construct = typedArrayConstructBigUint64, .namespace = .biguint64_array },
};

pub fn viewsRealm(rt: *Runtime) Error!*const ViewsRealm {
    _ = try realm(rt);
    const r = &rt.realm.?;
    if (r.views) |*v| return v;
    const h = &rt.heap;
    var v: ViewsRealm = .{
        .array_buffer_prototype = try builtin(h, r.object_prototype, .array_buffer_prototype),
        .array_buffer_namespace = try builtin(h, null, .array_buffer_constructor),
        .data_view_prototype = try builtin(h, r.object_prototype, .data_view_prototype),
        .data_view_namespace = try builtin(h, null, .data_view_constructor),
        .typed_array_prototype = try builtin(h, r.object_prototype, .typed_array_prototype),
        .typed_array_namespace = try builtin(h, null, .typed_array_constructor),
        .typed_array_prototypes = undefined,
        .typed_array_namespaces = undefined,
    };
    const ta_proto_builtins = [_]names.Builtin{
        .int8_array_prototype,
        .uint8_array_prototype,
        .uint8_clamped_array_prototype,
        .int16_array_prototype,
        .uint16_array_prototype,
        .int32_array_prototype,
        .uint32_array_prototype,
        .float32_array_prototype,
        .float64_array_prototype,
        .bigint64_array_prototype,
        .biguint64_array_prototype,
    };
    const ta_ctor_builtins = [_]names.Builtin{
        .int8_array_constructor,
        .uint8_array_constructor,
        .uint8_clamped_array_constructor,
        .int16_array_constructor,
        .uint16_array_constructor,
        .int32_array_constructor,
        .uint32_array_constructor,
        .float32_array_constructor,
        .float64_array_constructor,
        .bigint64_array_constructor,
        .biguint64_array_constructor,
    };
    for (0..11) |i| {
        v.typed_array_prototypes[i] = try builtin(h, v.typed_array_prototype, ta_proto_builtins[i]);
        v.typed_array_namespaces[i] = try builtin(h, null, ta_ctor_builtins[i]);
    }
    try initArrayBufferAndViews(rt, r, &v);
    r.views = v;
    return &r.views.?;
}

fn initArrayBufferAndViews(rt: *Runtime, r: *const Realm, v: *ViewsRealm) Error!void {
    // ArrayBuffer
    try rt.heap.defineProperty(v.array_buffer_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(v.array_buffer_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try method(rt, v.array_buffer_namespace, "isView", &ab_is_view);
    try object.defineAccessor(rt, Value.fromObject(v.array_buffer_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&species_getter), false, false);
    try constant(rt, v.array_buffer_prototype, "constructor", Value.fromNative(&array_buffer_global));
    try object.defineAccessor(rt, Value.fromObject(v.array_buffer_prototype), try object.named(rt, "byteLength"), Value.fromNative(&ab_byte_length_getter), false, false);
    try method(rt, v.array_buffer_prototype, "slice", &ab_slice);
    try defineToStringTag(rt, v.array_buffer_prototype, r.sym_to_string_tag, "ArrayBuffer");

    // DataView
    try rt.heap.defineProperty(v.data_view_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(v.data_view_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try constant(rt, v.data_view_prototype, "constructor", Value.fromNative(&data_view_global));
    try object.defineAccessor(rt, Value.fromObject(v.data_view_prototype), try object.named(rt, "buffer"), Value.fromNative(&dv_buffer_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.data_view_prototype), try object.named(rt, "byteLength"), Value.fromNative(&dv_byte_length_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.data_view_prototype), try object.named(rt, "byteOffset"), Value.fromNative(&dv_byte_offset_getter), false, false);
    try method(rt, v.data_view_prototype, "getInt8", &dv_get_int8);
    try method(rt, v.data_view_prototype, "setInt8", &dv_set_int8);
    try method(rt, v.data_view_prototype, "getUint8", &dv_get_uint8);
    try method(rt, v.data_view_prototype, "setUint8", &dv_set_uint8);
    try method(rt, v.data_view_prototype, "getInt16", &dv_get_int16);
    try method(rt, v.data_view_prototype, "setInt16", &dv_set_int16);
    try method(rt, v.data_view_prototype, "getUint16", &dv_get_uint16);
    try method(rt, v.data_view_prototype, "setUint16", &dv_set_uint16);
    try method(rt, v.data_view_prototype, "getInt32", &dv_get_int32);
    try method(rt, v.data_view_prototype, "setInt32", &dv_set_int32);
    try method(rt, v.data_view_prototype, "getUint32", &dv_get_uint32);
    try method(rt, v.data_view_prototype, "setUint32", &dv_set_uint32);
    try method(rt, v.data_view_prototype, "getFloat32", &dv_get_float32);
    try method(rt, v.data_view_prototype, "setFloat32", &dv_set_float32);
    try method(rt, v.data_view_prototype, "getFloat64", &dv_get_float64);
    try method(rt, v.data_view_prototype, "setFloat64", &dv_set_float64);
    try method(rt, v.data_view_prototype, "getBigInt64", &dv_get_bigint64);
    try method(rt, v.data_view_prototype, "setBigInt64", &dv_set_bigint64);
    try method(rt, v.data_view_prototype, "getBigUint64", &dv_get_biguint64);
    try method(rt, v.data_view_prototype, "setBigUint64", &dv_set_biguint64);
    try defineToStringTag(rt, v.data_view_prototype, r.sym_to_string_tag, "DataView");

    // %TypedArray%
    try rt.heap.defineProperty(v.typed_array_namespace, try rt.heap.internAscii("prototype"), .{
        .value = Value.fromObject(v.typed_array_prototype),
        .enumerable = false,
        .writable = false,
        .configurable = false,
    });
    try method(rt, v.typed_array_namespace, "from", &ta_from);
    try method(rt, v.typed_array_namespace, "of", &ta_of);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_namespace), .{ .symbol = r.sym_species }, Value.fromNative(&species_getter), false, false);
    try constant(rt, v.typed_array_prototype, "constructor", Value.fromNative(&typed_array_global));
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "buffer"), Value.fromNative(&ta_buffer_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "byteLength"), Value.fromNative(&ta_byte_length_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "byteOffset"), Value.fromNative(&ta_byte_offset_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), try object.named(rt, "length"), Value.fromNative(&ta_length_getter), false, false);
    try object.defineAccessor(rt, Value.fromObject(v.typed_array_prototype), .{ .symbol = r.sym_to_string_tag }, Value.fromNative(&ta_to_string_tag_getter), false, false);
    try method(rt, v.typed_array_prototype, "set", &ta_set);
    try method(rt, v.typed_array_prototype, "subarray", &ta_subarray);
    try method(rt, v.typed_array_prototype, "slice", &ta_slice);
    try method(rt, v.typed_array_prototype, "fill", &ta_fill);
    try method(rt, v.typed_array_prototype, "copyWithin", &ta_copy_within);
    try method(rt, v.typed_array_prototype, "reverse", &ta_reverse);
    try method(rt, v.typed_array_prototype, "sort", &ta_sort);
    try method(rt, v.typed_array_prototype, "indexOf", &ta_index_of);
    try method(rt, v.typed_array_prototype, "lastIndexOf", &ta_last_index_of);
    try method(rt, v.typed_array_prototype, "includes", &ta_includes);
    try method(rt, v.typed_array_prototype, "find", &ta_find);
    try method(rt, v.typed_array_prototype, "findIndex", &ta_find_index);
    try method(rt, v.typed_array_prototype, "findLast", &ta_find_last);
    try method(rt, v.typed_array_prototype, "findLastIndex", &ta_find_last_index);
    try method(rt, v.typed_array_prototype, "every", &ta_every);
    try method(rt, v.typed_array_prototype, "some", &ta_some);
    try method(rt, v.typed_array_prototype, "forEach", &ta_for_each);
    try method(rt, v.typed_array_prototype, "map", &ta_map);
    try method(rt, v.typed_array_prototype, "filter", &ta_filter);
    try method(rt, v.typed_array_prototype, "reduce", &ta_reduce);
    try method(rt, v.typed_array_prototype, "reduceRight", &ta_reduce_right);
    try method(rt, v.typed_array_prototype, "at", &ta_at);
    try method(rt, v.typed_array_prototype, "join", &ta_join);
    try method(rt, v.typed_array_prototype, "toString", &array_to_string);
    try method(rt, v.typed_array_prototype, "toLocaleString", &ta_to_locale_string);
    try method(rt, v.typed_array_prototype, "keys", &ta_keys);
    try method(rt, v.typed_array_prototype, "values", &ta_values);
    try method(rt, v.typed_array_prototype, "entries", &ta_entries);
    try symbolMethod(rt, v.typed_array_prototype, r.sym_iterator, &ta_values);

    // 11 concrete TypedArray constructors & prototypes
    const bpe_atom = try rt.heap.internAscii("BYTES_PER_ELEMENT");
    const proto_atom = try rt.heap.internAscii("prototype");
    const ctor_atom = try rt.heap.internAscii("constructor");
    for (0..11) |i| {
        const kind: heap_mod.TypedArrayKind = @fromBackingInt(@intCast(i));
        const bpe_val: Value = Value.fromNumber(@floatFromInt(kind.bytesPerElement()));
        const ns = v.typed_array_namespaces[i];
        const proto = v.typed_array_prototypes[i];
        try rt.heap.defineProperty(ns, proto_atom, .{
            .value = Value.fromObject(proto),
            .enumerable = false,
            .writable = false,
            .configurable = false,
        });
        try rt.heap.defineProperty(ns, bpe_atom, .{
            .value = bpe_val,
            .enumerable = false,
            .writable = false,
            .configurable = false,
        });
        try rt.heap.defineProperty(proto, ctor_atom, .{
            .value = Value.fromNative(&typed_array_ctors[i]),
            .enumerable = false,
            .writable = true,
            .configurable = true,
        });
        try rt.heap.defineProperty(proto, bpe_atom, .{
            .value = bpe_val,
            .enumerable = false,
            .writable = false,
            .configurable = false,
        });
    }
}

fn toIndex(rt: *Runtime, v: Value) Error!usize {
    if (v.isUndefined()) return 0;
    const n = try toIntegerOrInfinity(rt, v);
    if (n < 0 or n > 9007199254740991.0) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid array buffer length" }});
    }
    const max_usize_f: f64 = @floatFromInt(std.math.maxInt(usize));
    if (n > max_usize_f) return rt.heap.exceeded(.heap_bytes);
    return @intFromFloat(n);
}

fn relativeIndex(rt: *Runtime, v: Value, len: usize, default_val: usize) Error!usize {
    if (v.isUndefined()) return default_val;
    const n = try toIntegerOrInfinity(rt, v);
    const len_f: f64 = @floatFromInt(len);
    if (n < 0) {
        const res = len_f + n;
        return if (res <= 0) 0 else @intFromFloat(res);
    }
    return if (n >= len_f) len else @intFromFloat(n);
}

// ---- ArrayBuffer

fn arrayBufferWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor ArrayBuffer requires 'new'" }});
}

fn arrayBufferConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const byte_len = try toIndex(rt, arg(args, 0));
    const vr = try viewsRealm(rt);
    return Value.fromObject(try rt.heap.newArrayBuffer(vr.array_buffer_prototype, byte_len));
}

const ab_is_view: Native = .{ .name = "isView", .length = 1, .call = abIsView };
const ab_byte_length_getter: Native = .{ .name = "get byteLength", .call = abByteLengthGetter };
const ab_slice: Native = .{ .name = "slice", .length = 2, .call = abSlice };

fn abIsView(_: *Runtime, _: Value, args: []const Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return Value.fromBool(false);
    return Value.fromBool(switch (v.asObject().kind) {
        .typed_array, .data_view => true,
        else => false,
    });
}

fn requireArrayBuffer(rt: *Runtime, v: Value) Error!*Object {
    if (!v.isObject() or v.asObject().kind != .array_buffer) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method ArrayBuffer.prototype called on incompatible receiver" }});
    }
    return v.asObject();
}

fn abByteLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireArrayBuffer(rt, this);
    const ab = o.kind.array_buffer;
    return Value.fromNumber(if (ab.detached) 0 else @floatFromInt(ab.data.len));
}

fn abSlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireArrayBuffer(rt, this);
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (o.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot slice a detached ArrayBuffer" }});
    const len = o.kind.array_buffer.data.len;
    const first = try relativeIndex(rt, arg(args, 0), len, 0);
    const final = try relativeIndex(rt, arg(args, 1), len, len);
    const new_len = if (final > first) final - first else 0;
    const vr = try viewsRealm(rt);
    const new_ab = try rt.heap.newArrayBuffer(vr.array_buffer_prototype, new_len);
    if (o.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot slice a detached ArrayBuffer" }});
    if (new_len > 0) {
        @memcpy(new_ab.kind.array_buffer.data, o.kind.array_buffer.data[first .. first + new_len]);
    }
    return Value.fromObject(new_ab);
}

// ---- DataView

fn dataViewWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor DataView requires 'new'" }});
}

fn dataViewConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const buf_val = arg(args, 0);
    if (!buf_val.isObject() or buf_val.asObject().kind != .array_buffer) {
        return rt.throw(.TypeError, &.{.{ .ascii = "First argument to DataView constructor must be an ArrayBuffer" }});
    }
    var root_buf = [_]Value{buf_val};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const offset = try toIndex(rt, arg(args, 1));
    const ab = buf_val.asObject().kind.array_buffer;
    if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot construct DataView on a detached ArrayBuffer" }});
    if (offset > ab.data.len) return rt.throw(.RangeError, &.{.{ .ascii = "Start offset is outside the bounds of the buffer" }});
    const view_byte_len: usize = if (arg(args, 2).isUndefined())
        ab.data.len - offset
    else blk: {
        const l = try toIndex(rt, arg(args, 2));
        if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Cannot construct DataView on a detached ArrayBuffer" }});
        const end = std.math.add(usize, offset, l) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid DataView length" }});
        if (end > ab.data.len) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid DataView length" }});
        break :blk l;
    };
    const vr = try viewsRealm(rt);
    return Value.fromObject(try rt.heap.newDataView(vr.data_view_prototype, buf_val.asObject(), offset, view_byte_len));
}

fn requireDataView(rt: *Runtime, this: Value) Error!*Object {
    if (!this.isObject() or this.asObject().kind != .data_view) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method DataView.prototype called on incompatible receiver" }});
    }
    return this.asObject();
}

const dv_buffer_getter: Native = .{ .name = "get buffer", .call = dvBufferGetter };
const dv_byte_length_getter: Native = .{ .name = "get byteLength", .call = dvByteLengthGetter };
const dv_byte_offset_getter: Native = .{ .name = "get byteOffset", .call = dvByteOffsetGetter };

fn dvBufferGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    return Value.fromObject(o.kind.data_view.buffer);
}

fn dvByteLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
    return Value.fromNumber(@floatFromInt(dv.byte_length));
}

fn dvByteOffsetGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
    return Value.fromNumber(@floatFromInt(dv.byte_offset));
}

const DataViewElem = enum { int8, uint8, int16, uint16, int32, uint32, float32, float64, bigint64, biguint64 };

fn dvElemSize(comptime elem: DataViewElem) usize {
    return switch (elem) {
        .int8, .uint8 => 1,
        .int16, .uint16 => 2,
        .int32, .uint32, .float32 => 4,
        .float64, .bigint64, .biguint64 => 8,
    };
}

fn dvGet(comptime elem: DataViewElem, rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const get_idx = try toIndex(rt, arg(args, 0));
    const little = ops.toBoolean(arg(args, 1));
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
    const size = dvElemSize(elem);
    const end = std.math.add(usize, get_idx, size) catch return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    if (end > dv.byte_length) return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    const bytes = dv.buffer.kind.array_buffer.data[dv.byte_offset + get_idx ..];
    const endian: std.builtin.Endian = if (little) .little else .big;
    return switch (elem) {
        .bigint64 => Value.fromBigInt(try bigint.fromI64(rt, std.mem.readInt(i64, bytes[0..8], endian))),
        .biguint64 => Value.fromBigInt(try bigint.fromU64(rt, std.mem.readInt(u64, bytes[0..8], endian))),
        else => Value.fromNumber(switch (elem) {
            .int8 => @floatFromInt(@as(i8, @bitCast(bytes[0]))),
            .uint8 => @floatFromInt(bytes[0]),
            .int16 => @floatFromInt(std.mem.readInt(i16, bytes[0..2], endian)),
            .uint16 => @floatFromInt(std.mem.readInt(u16, bytes[0..2], endian)),
            .int32 => @floatFromInt(std.mem.readInt(i32, bytes[0..4], endian)),
            .uint32 => @floatFromInt(std.mem.readInt(u32, bytes[0..4], endian)),
            .float32 => @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], endian)))),
            .float64 => @bitCast(std.mem.readInt(u64, bytes[0..8], endian)),
            .bigint64, .biguint64 => unreachable,
        }),
    };
}

fn dvSet(comptime elem: DataViewElem, rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireDataView(rt, this);
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const get_idx = try toIndex(rt, arg(args, 0));
    const is_bigint = (elem == .bigint64 or elem == .biguint64);
    const big_val = if (is_bigint) try ops.toBigInt(rt, arg(args, 1)) else undefined;
    const n = if (!is_bigint) try ops.toNumber(rt, arg(args, 1)) else 0.0;
    const little = ops.toBoolean(arg(args, 2));
    const dv = o.kind.data_view;
    if (dv.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
    const size = dvElemSize(elem);
    const end = std.math.add(usize, get_idx, size) catch return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    if (end > dv.byte_length) return rt.throw(.RangeError, &.{.{ .ascii = "Offset is outside the bounds of the DataView" }});
    const bytes = dv.buffer.kind.array_buffer.data[dv.byte_offset + get_idx ..];
    const endian: std.builtin.Endian = if (little) .little else .big;
    switch (elem) {
        .int8 => bytes[0] = @bitCast(@as(i8, @truncate(ops.toInt32(n)))),
        .uint8 => bytes[0] = @truncate(ops.toUint32(n)),
        .int16 => std.mem.writeInt(i16, bytes[0..2], @truncate(ops.toInt32(n)), endian),
        .uint16 => std.mem.writeInt(u16, bytes[0..2], @truncate(ops.toUint32(n)), endian),
        .int32 => std.mem.writeInt(i32, bytes[0..4], ops.toInt32(n), endian),
        .uint32 => std.mem.writeInt(u32, bytes[0..4], ops.toUint32(n), endian),
        .float32 => {
            const f: f32 = @floatCast(n);
            std.mem.writeInt(u32, bytes[0..4], @bitCast(f), endian);
        },
        .float64 => std.mem.writeInt(u64, bytes[0..8], @bitCast(n), endian),
        .bigint64 => std.mem.writeInt(i64, bytes[0..8], bigint.toI64Wrapping(big_val), endian),
        .biguint64 => std.mem.writeInt(u64, bytes[0..8], bigint.toU64Wrapping(big_val), endian),
    }
    return .undefined;
}

const dv_get_int8: Native = .{ .name = "getInt8", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.int8, rt, t, a);
    }
}.f };
const dv_set_int8: Native = .{ .name = "setInt8", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.int8, rt, t, a);
    }
}.f };
const dv_get_uint8: Native = .{ .name = "getUint8", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.uint8, rt, t, a);
    }
}.f };
const dv_set_uint8: Native = .{ .name = "setUint8", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.uint8, rt, t, a);
    }
}.f };
const dv_get_int16: Native = .{ .name = "getInt16", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.int16, rt, t, a);
    }
}.f };
const dv_set_int16: Native = .{ .name = "setInt16", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.int16, rt, t, a);
    }
}.f };
const dv_get_uint16: Native = .{ .name = "getUint16", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.uint16, rt, t, a);
    }
}.f };
const dv_set_uint16: Native = .{ .name = "setUint16", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.uint16, rt, t, a);
    }
}.f };
const dv_get_int32: Native = .{ .name = "getInt32", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.int32, rt, t, a);
    }
}.f };
const dv_set_int32: Native = .{ .name = "setInt32", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.int32, rt, t, a);
    }
}.f };
const dv_get_uint32: Native = .{ .name = "getUint32", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.uint32, rt, t, a);
    }
}.f };
const dv_set_uint32: Native = .{ .name = "setUint32", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.uint32, rt, t, a);
    }
}.f };
const dv_get_float32: Native = .{ .name = "getFloat32", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.float32, rt, t, a);
    }
}.f };
const dv_set_float32: Native = .{ .name = "setFloat32", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.float32, rt, t, a);
    }
}.f };
const dv_get_float64: Native = .{ .name = "getFloat64", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.float64, rt, t, a);
    }
}.f };
const dv_set_float64: Native = .{ .name = "setFloat64", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.float64, rt, t, a);
    }
}.f };
const dv_get_bigint64: Native = .{ .name = "getBigInt64", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.bigint64, rt, t, a);
    }
}.f };
const dv_set_bigint64: Native = .{ .name = "setBigInt64", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.bigint64, rt, t, a);
    }
}.f };
const dv_get_biguint64: Native = .{ .name = "getBigUint64", .length = 1, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvGet(.biguint64, rt, t, a);
    }
}.f };
const dv_set_biguint64: Native = .{ .name = "setBigUint64", .length = 2, .call = struct {
    fn f(rt: *Runtime, t: Value, a: []const Value) Error!Value {
        return dvSet(.biguint64, rt, t, a);
    }
}.f };

// ---- %TypedArray% & Concrete Constructors

fn typedArrayAbstractCall(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Abstract class TypedArray not directly constructable" }});
}

fn typedArrayAbstractConstruct(rt: *Runtime, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Abstract class TypedArray not directly constructable" }});
}

fn typedArrayWithoutNew(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray constructor requires 'new'" }});
}

fn typedArrayConstructInt8(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .int8, args);
}
fn typedArrayConstructUint8(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint8, args);
}
fn typedArrayConstructUint8Clamped(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint8_clamped, args);
}
fn typedArrayConstructInt16(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .int16, args);
}
fn typedArrayConstructUint16(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint16, args);
}
fn typedArrayConstructInt32(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .int32, args);
}
fn typedArrayConstructUint32(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .uint32, args);
}
fn typedArrayConstructFloat32(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .float32, args);
}
fn typedArrayConstructFloat64(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .float64, args);
}
fn typedArrayConstructBigInt64(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .bigint64, args);
}
fn typedArrayConstructBigUint64(rt: *Runtime, args: []const Value) Error!Value {
    return typedArrayConstructKind(rt, .biguint64, args);
}

fn allocateTypedArray(rt: *Runtime, kind: heap_mod.TypedArrayKind, len: usize) Error!*Object {
    const vr = try viewsRealm(rt);
    const bpe = kind.bytesPerElement();
    const byte_len = std.math.mul(usize, len, bpe) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
    const ab = try rt.heap.newArrayBuffer(vr.array_buffer_prototype, byte_len);
    var root_buf = [_]Value{Value.fromObject(ab)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    return rt.heap.newTypedArray(vr.typed_array_prototypes[@backingInt(kind)], ab, kind, 0, len);
}

fn collectIterableToArray(rt: *Runtime, source: Value, method_fn: Value) Error!*Object {
    const r = try realm(rt);
    const arr = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ source, method_fn, Value.fromObject(arr), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const iter = try rt.callCallable(method_fn, source, &.{});
    if (!iter.isObject()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
    root_buf[3] = iter;
    const next_fn = try object.get(rt, iter, try object.named(rt, "next"));
    if (!next_fn.isFunction()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator next is not a function" }});
    root_buf[4] = next_fn;

    const done_key = try object.named(rt, "done");
    const value_key = try object.named(rt, "value");
    while (true) {
        try rt.step();
        const step = try rt.callCallable(next_fn, iter, &.{});
        if (!step.isObject()) return rt.throw(.TypeError, &.{.{ .ascii = "Iterator result is not an object" }});
        var step_buf = [_]Value{step};
        var step_roots: rt_mod.ValueRoots = .{ .values = &step_buf };
        try step_roots.register(rt);
        defer step_roots.unregister(rt);
        if (ops.toBoolean(try object.get(rt, step, done_key))) break;
        const val = try object.get(rt, step, value_key);
        try rt.heap.appendElement(arr, val);
    }
    return arr;
}

fn typedArrayConstructKind(rt: *Runtime, kind: heap_mod.TypedArrayKind, args: []const Value) Error!Value {
    const r = try realm(rt);
    const vr = try viewsRealm(rt);
    const proto = vr.typed_array_prototypes[@backingInt(kind)];
    if (args.len == 0) {
        return Value.fromObject(try allocateTypedArray(rt, kind, 0));
    }
    const arg0 = args[0];
    if (!arg0.isObject()) {
        const len = try toIndex(rt, arg0);
        return Value.fromObject(try allocateTypedArray(rt, kind, len));
    }
    switch (arg0.asObject().kind) {
        .typed_array => |src| {
            if (src.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Source TypedArray buffer is detached" }});
            if (src.kind.isBigInt() != kind.isBigInt()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other types, use explicit conversions" }});
            }
            var root_buf = [_]Value{arg0};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            const dst = try allocateTypedArray(rt, kind, src.length);
            const dst_ta = dst.kind.typed_array;
            for (0..src.length) |i| {
                const v = try object.readTypedArrayElement(rt, src, i);
                try object.writeTypedArrayElement(rt, dst_ta, i, v);
            }
            return Value.fromObject(dst);
        },
        .array_buffer => {
            var root_buf = [_]Value{arg0};
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            const bpe = kind.bytesPerElement();
            const offset = try toIndex(rt, arg(args, 1));
            if (offset % bpe != 0) {
                return rt.throw(.RangeError, &.{.{ .ascii = "Start offset of TypedArray should be a multiple of element size" }});
            }
            const ab = arg0.asObject().kind.array_buffer;
            if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
            const new_len: usize = if (arg(args, 2).isUndefined()) blk: {
                if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
                const buf_len = ab.data.len;
                if (buf_len % bpe != 0 or offset > buf_len) {
                    return rt.throw(.RangeError, &.{.{ .ascii = "Byte length of TypedArray should be a multiple of element size" }});
                }
                break :blk (buf_len - offset) / bpe;
            } else blk: {
                const l = try toIndex(rt, arg(args, 2));
                if (ab.detached) return rt.throw(.TypeError, &.{.{ .ascii = "ArrayBuffer is detached" }});
                const buf_len = ab.data.len;
                const needed = std.math.mul(usize, l, bpe) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
                const end = std.math.add(usize, offset, needed) catch return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
                if (end > buf_len) return rt.throw(.RangeError, &.{.{ .ascii = "Invalid typed array length" }});
                break :blk l;
            };
            return Value.fromObject(try rt.heap.newTypedArray(proto, arg0.asObject(), kind, offset, new_len));
        },
        else => {
            var root_buf = [_]Value{ arg0, .undefined };
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);

            if (try object.getMethod(rt, arg0, .{ .symbol = r.sym_iterator })) |iter_fn| {
                const arr = try collectIterableToArray(rt, arg0, iter_fn);
                root_buf[1] = Value.fromObject(arr);
                const len = arr.kind.array.items.len;
                const dst = try allocateTypedArray(rt, kind, len);
                root_buf[0] = Value.fromObject(dst);
                for (0..len) |i| {
                    try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, arr.kind.array.items[i]);
                }
                return Value.fromObject(dst);
            }
            const len_f = try toLength(rt, try object.get(rt, arg0, try object.named(rt, "length")));
            const len: usize = @intFromFloat(len_f);
            const dst = try allocateTypedArray(rt, kind, len);
            root_buf[1] = Value.fromObject(dst);
            for (0..len) |i| {
                const v = try object.get(rt, arg0, .{ .index = @intCast(i) });
                try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, v);
            }
            return Value.fromObject(dst);
        },
    }
}

fn constructorTypedArrayKind(v: Value) ?heap_mod.TypedArrayKind {
    if (!v.isNative()) return null;
    for (&typed_array_ctors, 0..) |*ctor, i| {
        if (v.asNative() == ctor) return @fromBackingInt(@intCast(i));
    }
    return null;
}

const ta_from: Native = .{ .name = "from", .length = 1, .call = taFrom };
const ta_of: Native = .{ .name = "of", .length = 0, .call = taOf };

fn typedArrayCreateLen(rt: *Runtime, ctor: Value, len: usize) Error!*Object {
    if (constructorTypedArrayKind(ctor)) |kind| {
        return allocateTypedArray(rt, kind, len);
    }
    const res = try constructWithNewTarget(rt, ctor, &.{Value.fromNumber(@floatFromInt(len))}, ctor);
    if (!res.isObject() or res.asObject().kind != .typed_array) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray constructor did not return a TypedArray" }});
    }
    if (res.asObject().kind.typed_array.length < len) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Derived TypedArray constructor created an array that was too small" }});
    }
    return res.asObject();
}

fn taFrom(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!isConstructor(this)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray.from requires a constructor" }});
    }
    const source = arg(args, 0);
    if (source.isUndefined() or source.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const map_fn = arg(args, 1);
    const has_map = !map_fn.isUndefined();
    if (has_map and !map_fn.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray.from mapFn is not a function" }});
    }
    const this_arg = arg(args, 2);
    const r = try realm(rt);
    var root_buf = [_]Value{ this, source, map_fn, this_arg, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (try object.getMethod(rt, source, .{ .symbol = r.sym_iterator })) |iter_fn| {
        const arr = try collectIterableToArray(rt, source, iter_fn);
        root_buf[4] = Value.fromObject(arr);
        const len = arr.kind.array.items.len;
        const dst = try typedArrayCreateLen(rt, this, len);
        root_buf[5] = Value.fromObject(dst);
        for (0..len) |i| {
            const elem = arr.kind.array.items[i];
            const val = if (has_map)
                try rt.callCallable(map_fn, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)) })
            else
                elem;
            _ = try object.setWithReceiver(rt, Value.fromObject(dst), .{ .index = @intCast(i) }, val, Value.fromObject(dst), true);
        }
        return Value.fromObject(dst);
    }

    const len_f = try toLength(rt, try object.get(rt, source, try object.named(rt, "length")));
    const len: usize = @intFromFloat(len_f);
    const dst = try typedArrayCreateLen(rt, this, len);
    root_buf[4] = Value.fromObject(dst);
    for (0..len) |i| {
        const elem = try object.get(rt, source, .{ .index = @intCast(i) });
        const val = if (has_map)
            try rt.callCallable(map_fn, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)) })
        else
            elem;
        _ = try object.setWithReceiver(rt, Value.fromObject(dst), .{ .index = @intCast(i) }, val, Value.fromObject(dst), true);
    }
    return Value.fromObject(dst);
}

fn taOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const kind = constructorTypedArrayKind(this) orelse {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray.of requires a TypedArray constructor" }});
    };
    const dst = try allocateTypedArray(rt, kind, args.len);
    var root_buf = [_]Value{Value.fromObject(dst)};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (args, 0..) |a, i| {
        try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, a);
    }
    return Value.fromObject(dst);
}

fn requireTypedArray(rt: *Runtime, this: Value) Error!*Object {
    if (!this.isObject() or this.asObject().kind != .typed_array) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Method TypedArray.prototype called on incompatible receiver" }});
    }
    return this.asObject();
}

fn requireLiveTypedArray(rt: *Runtime, this: Value) Error!*Object {
    const o = try requireTypedArray(rt, this);
    if (o.kind.typed_array.buffer.kind.array_buffer.detached) {
        return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
    }
    return o;
}

const ta_buffer_getter: Native = .{ .name = "get buffer", .call = taBufferGetter };
const ta_byte_length_getter: Native = .{ .name = "get byteLength", .call = taByteLengthGetter };
const ta_byte_offset_getter: Native = .{ .name = "get byteOffset", .call = taByteOffsetGetter };
const ta_length_getter: Native = .{ .name = "get length", .call = taLengthGetter };
const ta_to_string_tag_getter: Native = .{ .name = "get [Symbol.toStringTag]", .call = taToStringTagGetter };

fn taBufferGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    return Value.fromObject(o.kind.typed_array.buffer);
}

fn taByteLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(0);
    return Value.fromNumber(@floatFromInt(ta.length * ta.kind.bytesPerElement()));
}

fn taByteOffsetGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(0);
    return Value.fromNumber(@floatFromInt(ta.byte_offset));
}

fn taLengthGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(0);
    return Value.fromNumber(@floatFromInt(ta.length));
}

fn taToStringTagGetter(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (!this.isObject() or this.asObject().kind != .typed_array) return .undefined;
    return Value.fromString(try rt.heap.ascii(this.asObject().kind.typed_array.kind.name()));
}

const ta_set: Native = .{ .name = "set", .length = 1, .call = taSet };
const ta_subarray: Native = .{ .name = "subarray", .length = 2, .call = taSubarray };
const ta_slice: Native = .{ .name = "slice", .length = 2, .call = taSlice };
const ta_fill: Native = .{ .name = "fill", .length = 1, .call = taFill };
const ta_copy_within: Native = .{ .name = "copyWithin", .length = 2, .call = taCopyWithin };
const ta_reverse: Native = .{ .name = "reverse", .length = 0, .call = taReverse };
const ta_sort: Native = .{ .name = "sort", .length = 1, .call = taSort };
const ta_index_of: Native = .{ .name = "indexOf", .length = 1, .call = taIndexOf };
const ta_last_index_of: Native = .{ .name = "lastIndexOf", .length = 1, .call = taLastIndexOf };
const ta_includes: Native = .{ .name = "includes", .length = 1, .call = taIncludes };
const ta_find: Native = .{ .name = "find", .length = 1, .call = taFind };
const ta_find_index: Native = .{ .name = "findIndex", .length = 1, .call = taFindIndex };
const ta_find_last: Native = .{ .name = "findLast", .length = 1, .call = taFindLast };
const ta_find_last_index: Native = .{ .name = "findLastIndex", .length = 1, .call = taFindLastIndex };
const ta_every: Native = .{ .name = "every", .length = 1, .call = taEvery };
const ta_some: Native = .{ .name = "some", .length = 1, .call = taSome };
const ta_for_each: Native = .{ .name = "forEach", .length = 1, .call = taForEach };
const ta_map: Native = .{ .name = "map", .length = 1, .call = taMap };
const ta_filter: Native = .{ .name = "filter", .length = 1, .call = taFilter };
const ta_reduce: Native = .{ .name = "reduce", .length = 1, .call = taReduce };
const ta_reduce_right: Native = .{ .name = "reduceRight", .length = 1, .call = taReduceRight };
const ta_at: Native = .{ .name = "at", .length = 1, .call = taAt };
const ta_join: Native = .{ .name = "join", .length = 1, .call = taJoin };
const ta_to_locale_string: Native = .{ .name = "toLocaleString", .length = 0, .call = taToLocaleString };
const ta_keys: Native = .{ .name = "keys", .length = 0, .call = taKeys };
const ta_values: Native = .{ .name = "values", .length = 0, .call = taValues };
const ta_entries: Native = .{ .name = "entries", .length = 0, .call = taEntries };

fn taSet(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const dst = o.kind.typed_array;
    const src_val = arg(args, 0);
    var root_buf = [_]Value{ this, src_val };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const target_off_f = if (args.len > 1) try toIntegerOrInfinity(rt, arg(args, 1)) else 0.0;
    if (target_off_f < 0.0) return rt.throw(.RangeError, &.{.{ .ascii = "offset is out of bounds" }});
    if (dst.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});

    if (src_val.isObject() and src_val.asObject().kind == .typed_array) {
        const src = src_val.asObject().kind.typed_array;
        if (src.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "Source TypedArray buffer is detached" }});
        if (target_off_f + @as(f64, @floatFromInt(src.length)) > @as(f64, @floatFromInt(dst.length))) {
            return rt.throw(.RangeError, &.{.{ .ascii = "offset is out of bounds" }});
        }
        const target_off: usize = @intFromFloat(target_off_f);
        if (src.length == 0) return .undefined;
        const dst_bpe = dst.kind.bytesPerElement();
        const src_bpe = src.kind.bytesPerElement();
        const dst_data = dst.buffer.kind.array_buffer.data[dst.byte_offset + target_off * dst_bpe ..][0 .. src.length * dst_bpe];
        const src_data = src.buffer.kind.array_buffer.data[src.byte_offset..][0 .. src.length * src_bpe];
        if (src.kind.isBigInt() != dst.kind.isBigInt()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other types, use explicit conversions" }});
        }
        if (src.buffer == dst.buffer) {
            if (src.kind == dst.kind) {
                if (@intFromPtr(dst_data.ptr) < @intFromPtr(src_data.ptr)) {
                    std.mem.copyForwards(u8, dst_data, src_data);
                } else {
                    std.mem.copyBackwards(u8, dst_data, src_data);
                }
            } else if (src.kind.isBigInt()) {
                const tmp = try rt.gpa.alloc(Value, src.length);
                defer rt.gpa.free(tmp);
                for (0..src.length) |i| tmp[i] = try object.readTypedArrayElement(rt, src, i);
                for (tmp, 0..) |v, i| try object.writeTypedArrayElement(rt, dst, target_off + i, v);
            } else {
                const tmp = try rt.gpa.alloc(f64, src.length);
                defer rt.gpa.free(tmp);
                for (0..src.length) |i| tmp[i] = object.readTypedArrayNumber(src, i).asNumber();
                for (tmp, 0..) |n, i| object.writeTypedArrayNumber(dst, target_off + i, n);
            }
        } else if (src.kind == dst.kind) {
            @memcpy(dst_data, src_data);
        } else if (src.kind.isBigInt()) {
            for (0..src.length) |i| {
                const v = try object.readTypedArrayElement(rt, src, i);
                try object.writeTypedArrayElement(rt, dst, target_off + i, v);
            }
        } else {
            for (0..src.length) |i| {
                object.writeTypedArrayNumber(dst, target_off + i, object.readTypedArrayNumber(src, i).asNumber());
            }
        }
        return .undefined;
    }

    if (src_val.isNullish()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    const src_len_f = try toLength(rt, try object.get(rt, src_val, try object.named(rt, "length")));
    if (target_off_f + src_len_f > @as(f64, @floatFromInt(dst.length))) {
        return rt.throw(.RangeError, &.{.{ .ascii = "offset is out of bounds" }});
    }
    const target_off: usize = @intFromFloat(target_off_f);
    const src_len: usize = @intFromFloat(src_len_f);
    for (0..src_len) |i| {
        const v = try object.get(rt, src_val, .{ .index = @intCast(i) });
        try object.writeTypedArrayElement(rt, dst, target_off + i, v);
    }
    return .undefined;
}

fn typedArraySpeciesCreate(rt: *Runtime, exemplar: *Object, args: []const Value, min_len: ?usize) Error!*Object {
    const ta = exemplar.kind.typed_array;
    const default_ctor = Value.fromNative(&typed_array_ctors[@backingInt(ta.kind)]);
    const ctor = try speciesConstructor(rt, Value.fromObject(exemplar), default_ctor);
    if (ctor.isNative() and ctor.asNative() == &typed_array_ctors[@backingInt(ta.kind)]) {
        const created = try typedArrayConstructKind(rt, ta.kind, args);
        const dst = created.asObject();
        if (min_len) |ml| {
            if (dst.kind.typed_array.length < ml) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Derived TypedArray constructor created too small array" }});
            }
        }
        return dst;
    }
    const created = try constructValue(rt, ctor, args);
    const dst = try requireLiveTypedArray(rt, created);
    if (min_len) |ml| {
        if (dst.kind.typed_array.length < ml) {
            return rt.throw(.TypeError, &.{.{ .ascii = "Derived TypedArray constructor created too small array" }});
        }
    }
    return dst;
}

fn taSubarray(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const begin_idx = try relativeIndex(rt, arg(args, 0), ta.length, 0);
    const end_idx = try relativeIndex(rt, arg(args, 1), ta.length, ta.length);
    const new_len = if (end_idx > begin_idx) end_idx - begin_idx else 0;
    const new_off = ta.byte_offset + begin_idx * ta.kind.bytesPerElement();
    const dst = try typedArraySpeciesCreate(rt, o, &.{
        Value.fromObject(ta.buffer),
        Value.fromNumber(@floatFromInt(new_off)),
        Value.fromNumber(@floatFromInt(new_len)),
    }, null);
    return Value.fromObject(dst);
}

fn taSlice(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const start_idx = try relativeIndex(rt, arg(args, 0), ta.length, 0);
    const end_idx = try relativeIndex(rt, arg(args, 1), ta.length, ta.length);
    const count = if (end_idx > start_idx) end_idx - start_idx else 0;
    const dst = try typedArraySpeciesCreate(rt, o, &.{Value.fromNumber(@floatFromInt(count))}, count);
    root_buf[1] = Value.fromObject(dst);
    if (count > 0) {
        if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        const dst_ta = dst.kind.typed_array;
        if (dst_ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        if (dst_ta.kind == ta.kind and dst_ta.buffer != ta.buffer) {
            const bpe = ta.kind.bytesPerElement();
            const src_bytes = ta.buffer.kind.array_buffer.data[ta.byte_offset + start_idx * bpe ..][0 .. count * bpe];
            @memcpy(dst_ta.buffer.kind.array_buffer.data[dst_ta.byte_offset..][0 .. count * bpe], src_bytes);
        } else {
            if (ta.kind.isBigInt() != dst_ta.kind.isBigInt()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "Cannot mix BigInt and other TypedArray types" }});
            }
            for (0..count) |i| {
                const v = try object.readTypedArrayElement(rt, ta, start_idx + i);
                try object.writeTypedArrayElement(rt, dst_ta, i, v);
            }
        }
    }
    return Value.fromObject(dst);
}

fn taFill(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    if (ta.kind.isBigInt()) {
        const b = try ops.toBigInt(rt, arg(args, 0));
        const start_idx = try relativeIndex(rt, arg(args, 1), ta.length, 0);
        const end_idx = try relativeIndex(rt, arg(args, 2), ta.length, ta.length);
        if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        if (end_idx > start_idx) {
            for (start_idx..end_idx) |i| object.writeTypedArrayBigInt(ta, i, b);
        }
    } else {
        const val = try ops.toNumber(rt, arg(args, 0));
        const start_idx = try relativeIndex(rt, arg(args, 1), ta.length, 0);
        const end_idx = try relativeIndex(rt, arg(args, 2), ta.length, ta.length);
        if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
        if (end_idx > start_idx) {
            for (start_idx..end_idx) |i| object.writeTypedArrayNumber(ta, i, val);
        }
    }
    return this;
}

fn taCopyWithin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const to_idx = try relativeIndex(rt, arg(args, 0), ta.length, 0);
    const from_idx = try relativeIndex(rt, arg(args, 1), ta.length, 0);
    const end_idx = try relativeIndex(rt, arg(args, 2), ta.length, ta.length);
    if (end_idx <= from_idx or to_idx >= ta.length) return this;
    const count = @min(end_idx - from_idx, ta.length - to_idx);
    if (ta.buffer.kind.array_buffer.detached) return rt.throw(.TypeError, &.{.{ .ascii = "TypedArray buffer is detached" }});
    const bpe = ta.kind.bytesPerElement();
    const data = ta.buffer.kind.array_buffer.data;
    const dst_bytes = data[ta.byte_offset + to_idx * bpe ..][0 .. count * bpe];
    const src_bytes = data[ta.byte_offset + from_idx * bpe ..][0 .. count * bpe];
    if (to_idx < from_idx) {
        std.mem.copyForwards(u8, dst_bytes, src_bytes);
    } else if (to_idx > from_idx) {
        std.mem.copyBackwards(u8, dst_bytes, src_bytes);
    }
    return this;
}

fn taReverse(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length <= 1) return this;
    const bpe = ta.kind.bytesPerElement();
    const data = ta.buffer.kind.array_buffer.data[ta.byte_offset..][0 .. ta.length * bpe];
    var i: usize = 0;
    var j: usize = ta.length - 1;
    var tmp: [8]u8 = undefined;
    while (i < j) : ({
        i += 1;
        j -= 1;
    }) {
        const a_slice = data[i * bpe ..][0..bpe];
        const b_slice = data[j * bpe ..][0..bpe];
        @memcpy(tmp[0..bpe], a_slice);
        @memcpy(a_slice, b_slice);
        @memcpy(b_slice, tmp[0..bpe]);
    }
    return this;
}

fn numericSortLess(_: void, a: f64, b: f64) bool {
    if (std.math.isNan(a)) return false;
    if (std.math.isNan(b)) return true;
    if (a < b) return true;
    if (a > b) return false;
    // -0 before +0
    return std.math.signbit(a) and !std.math.signbit(b);
}

fn mergeSortTypedArray(
    rt: *Runtime,
    arr: []f64,
    tmp: []f64,
    cmp: Value,
) Error!void {
    if (arr.len <= 1) return;
    const mid = arr.len / 2;
    try mergeSortTypedArray(rt, arr[0..mid], tmp[0..mid], cmp);
    try mergeSortTypedArray(rt, arr[mid..], tmp[mid..], cmp);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < arr.len) : (k += 1) {
        try rt.step();
        const res = try rt.callCallable(cmp, .undefined, &.{ Value.fromNumber(arr[i]), Value.fromNumber(arr[j]) });
        const order = try ops.toNumber(rt, res);
        if (order <= 0 or std.math.isNan(order)) {
            tmp[k] = arr[i];
            i += 1;
        } else {
            tmp[k] = arr[j];
            j += 1;
        }
    }
    while (i < mid) : ({
        i += 1;
        k += 1;
    }) tmp[k] = arr[i];
    while (j < arr.len) : ({
        j += 1;
        k += 1;
    }) tmp[k] = arr[j];
    @memcpy(arr, tmp[0..arr.len]);
}

fn mergeSortTypedArrayValues(
    rt: *Runtime,
    arr: []Value,
    tmp: []Value,
    cmp: Value,
) Error!void {
    if (arr.len <= 1) return;
    const mid = arr.len / 2;
    try mergeSortTypedArrayValues(rt, arr[0..mid], tmp[0..mid], cmp);
    try mergeSortTypedArrayValues(rt, arr[mid..], tmp[mid..], cmp);
    var i: usize = 0;
    var j: usize = mid;
    var k: usize = 0;
    while (i < mid and j < arr.len) : (k += 1) {
        try rt.step();
        const res = try rt.callCallable(cmp, .undefined, &.{ arr[i], arr[j] });
        const order = try ops.toNumber(rt, res);
        if (order <= 0 or std.math.isNan(order)) {
            tmp[k] = arr[i];
            i += 1;
        } else {
            tmp[k] = arr[j];
            j += 1;
        }
    }
    while (i < mid) : ({
        i += 1;
        k += 1;
    }) tmp[k] = arr[i];
    while (j < arr.len) : ({
        j += 1;
        k += 1;
    }) tmp[k] = arr[j];
    @memcpy(arr, tmp[0..arr.len]);
}

fn taSort(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cmp = arg(args, 0);
    if (!cmp.isUndefined() and !cmp.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "The comparison function must be either a function or undefined" }});
    }
    const ta = o.kind.typed_array;
    if (ta.length <= 1) return this;

    if (ta.kind.isBigInt()) {
        if (cmp.isUndefined()) {
            if (ta.kind == .bigint64) {
                const vals = try rt.gpa.alloc(i64, ta.length);
                defer rt.gpa.free(vals);
                for (0..ta.length) |i| vals[i] = object.readTypedArrayI64(ta, i);
                std.mem.sort(i64, vals, {}, std.sort.asc(i64));
                const data = ta.buffer.kind.array_buffer.data;
                const native_endian = @import("builtin").cpu.arch.endian();
                for (vals, 0..) |v, i| {
                    std.mem.writeInt(i64, data[ta.byte_offset + i * 8 ..][0..8], v, native_endian);
                }
            } else {
                const vals = try rt.gpa.alloc(u64, ta.length);
                defer rt.gpa.free(vals);
                for (0..ta.length) |i| vals[i] = object.readTypedArrayU64(ta, i);
                std.mem.sort(u64, vals, {}, std.sort.asc(u64));
                const data = ta.buffer.kind.array_buffer.data;
                const native_endian = @import("builtin").cpu.arch.endian();
                for (vals, 0..) |v, i| {
                    std.mem.writeInt(u64, data[ta.byte_offset + i * 8 ..][0..8], v, native_endian);
                }
            }
        } else {
            const vals = try rt.gpa.alloc(Value, ta.length);
            defer rt.gpa.free(vals);
            for (0..ta.length) |i| vals[i] = try object.readTypedArrayElement(rt, ta, i);
            var root_buf = [_]Value{ this, cmp };
            var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
            try roots.register(rt);
            defer roots.unregister(rt);
            var val_roots: rt_mod.ValueRoots = .{ .values = vals };
            try val_roots.register(rt);
            defer val_roots.unregister(rt);
            const scratch = try rt.gpa.alloc(Value, ta.length);
            defer rt.gpa.free(scratch);
            try mergeSortTypedArrayValues(rt, vals, scratch, cmp);
            for (vals, 0..) |v, i| try object.writeTypedArrayElement(rt, ta, i, v);
        }
        return this;
    }

    const vals = try rt.gpa.alloc(f64, ta.length);
    defer rt.gpa.free(vals);
    for (0..ta.length) |i| vals[i] = object.readTypedArrayNumber(ta, i).asNumber();

    if (cmp.isUndefined()) {
        std.mem.sort(f64, vals, {}, numericSortLess);
    } else {
        var root_buf = [_]Value{ this, cmp };
        var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
        try roots.register(rt);
        defer roots.unregister(rt);
        const scratch = try rt.gpa.alloc(f64, ta.length);
        defer rt.gpa.free(scratch);
        try mergeSortTypedArray(rt, vals, scratch, cmp);
    }
    for (vals, 0..) |n, i| object.writeTypedArrayNumber(ta, i, n);
    return this;
}

fn taIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length == 0) return Value.fromNumber(-1);
    const search = arg(args, 0);
    const from_n = if (args.len > 1) try toIntegerOrInfinity(rt, arg(args, 1)) else 0.0;
    if (ta.kind.isBigInt()) {
        if (!search.isBigInt()) return Value.fromNumber(-1);
    } else if (!search.isNumber()) return Value.fromNumber(-1);
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
    const len_f: f64 = @floatFromInt(ta.length);
    if (from_n >= len_f) return Value.fromNumber(-1);
    const start: usize = if (from_n < 0) blk: {
        const k = len_f + from_n;
        break :blk if (k <= 0) 0 else @intFromFloat(k);
    } else @intFromFloat(from_n);
    for (start..ta.length) |i| {
        if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (ops.strictEquals(elem, search)) return Value.fromNumber(@floatFromInt(i));
    }
    return Value.fromNumber(-1);
}

fn taLastIndexOf(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length == 0) return Value.fromNumber(-1);
    const search = arg(args, 0);
    const len_f: f64 = @floatFromInt(ta.length);
    const from_n = if (args.len > 1) try toIntegerOrInfinity(rt, arg(args, 1)) else len_f - 1.0;
    if (ta.kind.isBigInt()) {
        if (!search.isBigInt()) return Value.fromNumber(-1);
    } else if (!search.isNumber()) return Value.fromNumber(-1);
    if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
    const k_f = if (from_n >= 0) @min(from_n, len_f - 1.0) else len_f + from_n;
    if (k_f < 0) return Value.fromNumber(-1);
    var i: usize = @intFromFloat(k_f);
    while (true) {
        if (ta.buffer.kind.array_buffer.detached) return Value.fromNumber(-1);
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (ops.strictEquals(elem, search)) return Value.fromNumber(@floatFromInt(i));
        if (i == 0) break;
        i -= 1;
    }
    return Value.fromNumber(-1);
}

fn taIncludes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    if (ta.length == 0) return Value.fromBool(false);
    const search = arg(args, 0);
    const from_n = if (args.len > 1) try toIntegerOrInfinity(rt, arg(args, 1)) else 0.0;
    const len_f: f64 = @floatFromInt(ta.length);
    if (from_n >= len_f) return Value.fromBool(false);
    const start: usize = if (from_n < 0) blk: {
        const k = len_f + from_n;
        break :blk if (k <= 0) 0 else @intFromFloat(k);
    } else @intFromFloat(from_n);
    for (start..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (heap_mod.sameValueZero(elem, search)) return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

fn taAt(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    const idx_f = try toIntegerOrInfinity(rt, arg(args, 0));
    const len_f: f64 = @floatFromInt(ta.length);
    const k = if (idx_f >= 0) idx_f else len_f + idx_f;
    if (k < 0 or k >= len_f) return .undefined;
    return object.readTypedArrayElement(rt, ta, @intFromFloat(k));
}

fn taJoin(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var sep_buf: ops.NumberBuf = undefined;
    var sep_units_buf: [64]u16 = undefined;
    const sep: []const u16 = if (arg(args, 0).isUndefined())
        &.{','}
    else switch (try ops.toPiece(rt, arg(args, 0), &sep_buf)) {
        .utf16 => |u| u,
        .ascii => |a| blk: {
            for (a, 0..) |c, i| sep_units_buf[i] = c;
            break :blk sep_units_buf[0..a.len];
        },
    };
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    for (0..ta.length) |i| {
        if (i > 0) try out.appendSlice(rt.gpa, sep);
        var buf: ops.NumberBuf = undefined;
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (elem.isUndefined()) continue;
        switch (try ops.toPiece(rt, elem, &buf)) {
            .ascii => |s| for (s) |c| try out.append(rt.gpa, c),
            .utf16 => |u| try out.appendSlice(rt.gpa, u),
        }
        if (out.items.len > rt.heap.max_string_length) return rt.limit(.string_length);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn taToLocaleString(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(rt.gpa);
    for (0..ta.length) |i| {
        if (i > 0) try out.append(rt.gpa, ',');
        const elem = try object.readTypedArrayElement(rt, ta, i);
        if (elem.isUndefined() or elem.isNull()) continue;
        root_buf[1] = elem;
        const m = try object.get(rt, elem, try object.named(rt, "toLocaleString"));
        if (m.isNative() or m.isClosure()) {
            const res = try rt.callCallable(m, elem, args);
            const str = try toStringObj(rt, res);
            root_buf[2] = Value.fromString(str);
            try appendUnits(rt, &out, str.units);
        } else {
            var buf: ops.NumberBuf = undefined;
            switch (try ops.toPiece(rt, elem, &buf)) {
                .ascii => |s| for (s) |c| try out.append(rt.gpa, c),
                .utf16 => |u| try appendUnits(rt, &out, u),
            }
        }
        if (out.items.len > rt.heap.max_string_length) return rt.limit(.string_length);
    }
    return Value.fromString(try rt.heap.newString(&.{.{ .utf16 = out.items }}));
}

fn taKeys(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try requireLiveTypedArray(rt, this);
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_keys));
}

fn taValues(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try requireLiveTypedArray(rt, this);
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_values));
}

fn taEntries(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    _ = try requireLiveTypedArray(rt, this);
    return Value.fromObject(try rt.heap.newIterator((try realm(rt)).iterator_prototype, this, .array_entries));
}

fn taForEach(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        _ = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
    }
    return .undefined;
}

fn taEvery(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (!ops.toBoolean(res)) return Value.fromBool(false);
    }
    return Value.fromBool(true);
}

fn taSome(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (ops.toBoolean(res)) return Value.fromBool(true);
    }
    return Value.fromBool(false);
}

fn taFindImpl(rt: *Runtime, this: Value, args: []const Value, reverse: bool, return_index: bool) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (ta.length == 0) return if (return_index) Value.fromNumber(-1) else .undefined;
    var i: usize = if (reverse) ta.length - 1 else 0;
    while (true) {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (ops.toBoolean(res)) return if (return_index) Value.fromNumber(@floatFromInt(i)) else elem;
        if (reverse) {
            if (i == 0) break;
            i -= 1;
        } else {
            i += 1;
            if (i >= ta.length) break;
        }
    }
    return if (return_index) Value.fromNumber(-1) else .undefined;
}

fn taFind(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, false, false);
}
fn taFindIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, false, true);
}
fn taFindLast(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, true, false);
}
fn taFindLastIndex(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taFindImpl(rt, this, args, true, true);
}

fn taMap(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const dst = try typedArraySpeciesCreate(rt, o, &.{Value.fromNumber(@floatFromInt(ta.length))}, ta.length);
    root_buf[3] = Value.fromObject(dst);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        const mapped = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, mapped);
    }
    return Value.fromObject(dst);
}

fn taFilter(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try requireCallable(rt, arg(args, 0));
    const this_arg = arg(args, 1);
    const ta = o.kind.typed_array;
    var root_buf = [_]Value{ this, cb, this_arg, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    var kept: std.ArrayList(Value) = .empty;
    defer kept.deinit(rt.gpa);
    for (0..ta.length) |i| {
        const elem = try object.readTypedArrayElement(rt, ta, i);
        root_buf[3] = elem;
        var kept_roots: rt_mod.ValueRoots = .{ .values = kept.items };
        try kept_roots.register(rt);
        defer kept_roots.unregister(rt);
        const res = try rt.callCallable(cb, this_arg, &.{ elem, Value.fromNumber(@floatFromInt(i)), this });
        if (ops.toBoolean(res)) try kept.append(rt.gpa, root_buf[3]);
    }
    var kept_roots: rt_mod.ValueRoots = .{ .values = kept.items };
    try kept_roots.register(rt);
    defer kept_roots.unregister(rt);
    const dst = try typedArraySpeciesCreate(rt, o, &.{Value.fromNumber(@floatFromInt(kept.items.len))}, kept.items.len);
    root_buf[3] = Value.fromObject(dst);
    for (kept.items, 0..) |v, i| try object.writeTypedArrayElement(rt, dst.kind.typed_array, i, v);
    return Value.fromObject(dst);
}

fn taReduceImpl(rt: *Runtime, this: Value, args: []const Value, right: bool) Error!Value {
    const o = try requireLiveTypedArray(rt, this);
    const cb = try requireCallable(rt, arg(args, 0));
    const ta = o.kind.typed_array;
    if (ta.length == 0 and args.len < 2) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reduce of empty typed array with no initial value" }});
    }
    var acc: Value = undefined;
    var start_i: usize = undefined;
    if (args.len >= 2) {
        acc = arg(args, 1);
        start_i = if (right) ta.length else 0;
    } else {
        acc = try object.readTypedArrayElement(rt, ta, if (right) ta.length - 1 else 0);
        start_i = if (right) ta.length - 1 else 1;
    }
    var root_buf = [_]Value{ this, cb, acc };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    if (right) {
        var i = start_i;
        while (i > 0) {
            i -= 1;
            const elem = try object.readTypedArrayElement(rt, ta, i);
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(i)), this });
        }
    } else {
        for (start_i..ta.length) |i| {
            const elem = try object.readTypedArrayElement(rt, ta, i);
            root_buf[2] = try rt.callCallable(cb, .undefined, &.{ root_buf[2], elem, Value.fromNumber(@floatFromInt(i)), this });
        }
    }
    return root_buf[2];
}

fn taReduce(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taReduceImpl(rt, this, args, false);
}
fn taReduceRight(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return taReduceImpl(rt, this, args, true);
}

// ---------------------------------------------------------------- Proxy & Reflect (M46, D76)

const proxy_global: Native = .{
    .name = "Proxy",
    .length = 2,
    .call = proxyCallThrow,
    .construct = proxyConstruct,
    .namespace = .proxy,
};
const proxy_revocable: Native = .{ .name = "revocable", .length = 2, .call = proxyRevocable };

const reflect_get: Native = .{ .name = "get", .length = 2, .call = reflectGet };
const reflect_set: Native = .{ .name = "set", .length = 3, .call = reflectSet };
const reflect_has: Native = .{ .name = "has", .length = 2, .call = reflectHas };
const reflect_delete_property: Native = .{ .name = "deleteProperty", .length = 2, .call = reflectDeleteProperty };
const reflect_own_keys: Native = .{ .name = "ownKeys", .length = 1, .call = reflectOwnKeys };
const reflect_get_own_property_descriptor: Native = .{ .name = "getOwnPropertyDescriptor", .length = 2, .call = reflectGetOwnPropertyDescriptor };
const reflect_define_property: Native = .{ .name = "defineProperty", .length = 3, .call = reflectDefineProperty };
const reflect_get_prototype_of: Native = .{ .name = "getPrototypeOf", .length = 1, .call = reflectGetPrototypeOf };
const reflect_set_prototype_of: Native = .{ .name = "setPrototypeOf", .length = 2, .call = reflectSetPrototypeOf };
const reflect_is_extensible: Native = .{ .name = "isExtensible", .length = 1, .call = reflectIsExtensible };
const reflect_prevent_extensions: Native = .{ .name = "preventExtensions", .length = 1, .call = reflectPreventExtensions };
const reflect_apply: Native = .{ .name = "apply", .length = 3, .call = reflectApply };
const reflect_construct: Native = .{ .name = "construct", .length = 2, .call = reflectConstruct };

fn proxyCallThrow(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return rt.throw(.TypeError, &.{.{ .ascii = "Constructor Proxy requires 'new'" }});
}

fn proxyConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const target = arg(args, 0);
    const handler = arg(args, 1);
    if (!target.isObjectLike() or !handler.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot create proxy with a non-object as target or handler" }});
    }
    if (target.isObject() and target.asObject().kind == .proxy and target.asObject().kind.proxy.target == null) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot create proxy with a revoked proxy as target" }});
    }
    if (handler.isObject() and handler.asObject().kind == .proxy and handler.asObject().kind.proxy.target == null) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot create proxy with a revoked proxy as handler" }});
    }
    const is_callable = target.isFunction();
    const is_constructable = isConstructor(target);
    const px = try rt.heap.newProxy(null, target, handler, is_callable, is_constructable);
    return Value.fromObject(px);
}

fn proxyRevokeFn(rt: *Runtime, env: *Object, _: []const Value) Error!Value {
    const k = try rt.heap.internAscii("p");
    const pk = heap_mod.PropKey.fromAtom(k);
    if (env.props.get(pk)) |prop| {
        if (prop.value.isObject() and prop.value.asObject().kind == .proxy) {
            heap_mod.Heap.revokeProxy(prop.value.asObject());
        }
        try rt.heap.removePropKey(env, pk);
    }
    return .undefined;
}

fn proxyRevocable(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const px_val = try proxyConstruct(rt, args);
    const r = try realm(rt);
    var root_buf = [_]Value{ px_val, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const env = try rt.heap.newObject(null);
    root_buf[1] = Value.fromObject(env);
    try rt.heap.storeProperty(env, try rt.heap.internAscii("p"), px_val);
    const revoke_fn = try rt.heap.newNativeClosure(@ptrCast(&proxyRevokeFn), env);
    root_buf[2] = Value.fromClosure(revoke_fn);

    const out = try rt.heap.newObject(r.object_prototype);
    try rt.heap.storeProperty(out, try rt.heap.internAscii("proxy"), px_val);
    try rt.heap.storeProperty(out, try rt.heap.internAscii("revoke"), Value.fromClosure(revoke_fn));
    return Value.fromObject(out);
}

const ProxyTrap = struct {
    target: Value,
    handler: Value,
    trap: ?Value,
};

fn getProxyTrap(rt: *Runtime, px_obj: *Object, trap_name: []const u8) Error!ProxyTrap {
    try rt.checkNativeStack();
    const px = px_obj.kind.proxy;
    const target = px.target orelse return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot perform '" }, .{ .ascii = trap_name }, .{ .ascii = "' on a proxy that has been revoked" } });
    const handler = px.handler orelse return rt.throw(.TypeError, &.{ .{ .ascii = "Cannot perform '" }, .{ .ascii = trap_name }, .{ .ascii = "' on a proxy that has been revoked" } });
    var root_buf = [_]Value{ target, handler };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const trap = try object.getMethod(rt, handler, try object.named(rt, trap_name));
    return .{ .target = target, .handler = handler, .trap = trap };
}

fn keyToValue(rt: *Runtime, k: object.Key) Error!Value {
    return switch (k) {
        .atom => |a| Value.fromString(a),
        .symbol => |s| Value.fromSymbol(s),
        .index => |i| Value.fromString(try keyToString(rt, .{ .index = i })),
    };
}

pub fn proxyGet(rt: *Runtime, px_obj: *Object, k: object.Key, receiver: Value) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(px_obj), receiver, keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "get");
    if (t.trap == null) return object.getWithReceiver(rt, t.target, receiver, k);
    const prop_val = try keyToValue(rt, k);
    root_buf[3] = t.target;
    root_buf[4] = t.handler;
    root_buf[5] = prop_val;

    const trap_res = try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val, receiver });
    root_buf[4] = trap_res;

    if (try getOwnPropertyRaw(rt, t.target, k)) |td| {
        if (!td.configurable) {
            if (!td.is_accessor and !td.writable and !sameValue(trap_res, td.value)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'get' on proxy: property is a read-only and non-configurable data property on the proxy target but the proxy did not return its actual value" }});
            }
            if (td.is_accessor and td.value.isUndefined() and !trap_res.isUndefined()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'get' on proxy: property is a non-configurable accessor without a getter on the proxy target but the proxy did not return undefined" }});
            }
        }
    }
    return trap_res;
}

pub fn proxySet(rt: *Runtime, px_obj: *Object, k: object.Key, v: Value, receiver: Value) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), v, receiver, keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "set");
    if (t.trap == null) return object.setWithReceiver(rt, t.target, k, v, receiver, false);
    const prop_val = try keyToValue(rt, k);
    root_buf[4] = t.target;
    root_buf[5] = t.handler;
    root_buf[6] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val, v, receiver }));
    if (!trap_res) return false;

    if (try getOwnPropertyRaw(rt, t.target, k)) |td| {
        if (!td.configurable) {
            if (!td.is_accessor and !td.writable and !sameValue(v, td.value)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'set' on proxy: trap returned truish for property which exists in the proxy target as a non-configurable and non-writable data property with a different value" }});
            }
            if (td.is_accessor and td.setter.isUndefined()) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'set' on proxy: trap returned truish for property which exists in the proxy target as a non-configurable accessor without a setter" }});
            }
        }
    }
    return true;
}

pub fn proxyHas(rt: *Runtime, px_obj: *Object, k: object.Key) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "has");
    if (t.trap == null) return object.has(rt, k, t.target);
    const prop_val = try keyToValue(rt, k);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;
    root_buf[4] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val }));
    if (!trap_res) {
        if (try getOwnPropertyRaw(rt, t.target, k)) |td| {
            if (!td.configurable) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'has' on proxy: trap returned falsish for property which exists in the proxy target as non-configurable" }});
            }
            if (!try isExtensibleValue(rt, t.target)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'has' on proxy: trap returned falsish for property but the proxy target is not extensible" }});
            }
        }
    }
    return trap_res;
}

pub fn proxyDeleteProperty(rt: *Runtime, px_obj: *Object, k: object.Key) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "deleteProperty");
    if (t.trap == null) return object.delete(rt, t.target, k);
    const prop_val = try keyToValue(rt, k);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;
    root_buf[4] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val }));
    if (!trap_res) return false;

    if (try getOwnPropertyRaw(rt, t.target, k)) |td| {
        if (!td.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'deleteProperty' on proxy: trap returned truish for property which is non-configurable in the proxy target" }});
        }
        if (!try isExtensibleValue(rt, t.target)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'deleteProperty' on proxy: trap returned truish for property but the proxy target is non-extensible" }});
        }
    }
    return true;
}

pub fn proxyGetPrototypeOf(rt: *Runtime, px_obj: *Object) Error!Value {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "getPrototypeOf");
    if (t.trap == null) return object.getPrototypeOfValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const handler_proto = try rt.callCallable(t.trap.?, t.handler, &.{t.target});
    root_buf[2] = handler_proto;
    if (!handler_proto.isNull() and !handler_proto.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'getPrototypeOf' on proxy: trap returned neither object nor null" }});
    }
    if (try isExtensibleValue(rt, t.target)) return handler_proto;
    const target_proto = try object.getPrototypeOfValue(rt, t.target);
    if (!sameValue(handler_proto, target_proto)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'getPrototypeOf' on proxy: proxy target is non-extensible but the trap did not return its actual prototype" }});
    }
    return handler_proto;
}

fn proxySetPrototypeOf(rt: *Runtime, px_obj: *Object, proto: Value) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), proto, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "setPrototypeOf");
    if (t.trap == null) return setPrototypeOfValue(rt, t.target, proto);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, proto }));
    if (!trap_res) return false;
    if (try isExtensibleValue(rt, t.target)) return true;
    const target_proto = try object.getPrototypeOfValue(rt, t.target);
    if (!sameValue(proto, target_proto)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'setPrototypeOf' on proxy: trap returned truish for setting a new prototype on the non-extensible proxy target" }});
    }
    return true;
}

fn proxyIsExtensible(rt: *Runtime, px_obj: *Object) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "isExtensible");
    if (t.trap == null) return isExtensibleValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{t.target}));
    const target_ext = try isExtensibleValue(rt, t.target);
    if (trap_res != target_ext) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'isExtensible' on proxy: trap result does not reflect extensibility of proxy target" }});
    }
    return trap_res;
}

fn proxyPreventExtensions(rt: *Runtime, px_obj: *Object) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "preventExtensions");
    if (t.trap == null) return preventExtensionsValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{t.target}));
    if (trap_res and try isExtensibleValue(rt, t.target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'preventExtensions' on proxy: trap returned truish but the proxy target is extensible" }});
    }
    return trap_res;
}

pub fn proxyGetOwnPropertyDescriptor(rt: *Runtime, px_obj: *Object, k: object.Key) Error!?heap_mod.Property {
    var root_buf = [_]Value{ Value.fromObject(px_obj), keyToRootValue(k), .undefined, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "getOwnPropertyDescriptor");
    if (t.trap == null) return getOwnPropertyRaw(rt, t.target, k);
    const prop_val = try keyToValue(rt, k);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;
    root_buf[4] = prop_val;

    const trap_res = try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val });
    root_buf[3] = trap_res;
    if (!trap_res.isUndefined() and !trap_res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined" }});
    }

    const target_desc = try getOwnPropertyRaw(rt, t.target, k);
    if (trap_res.isUndefined()) {
        if (target_desc) |td| {
            if (!td.configurable) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned undefined for property which is non-configurable in the proxy target" }});
            }
            if (!try isExtensibleValue(rt, t.target)) {
                return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned undefined for property which exists in the non-extensible proxy target" }});
            }
        }
        return null;
    }

    const extensible_target = try isExtensibleValue(rt, t.target);
    const parsed = try parsePropertyDescriptor(rt, trap_res);
    const result_desc = parsed.toCompleteProperty();
    root_buf[4] = result_desc.value;
    root_buf[5] = result_desc.setter;

    if (target_desc == null) {
        if (!extensible_target) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned descriptor for property that does not exist on the non-extensible proxy target" }});
        }
        if (!result_desc.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned non-configurable descriptor for property that does not exist in the proxy target" }});
        }
    } else {
        const td = target_desc.?;
        const completed_parsed: ParsedDesc = if (result_desc.is_accessor) .{
            .has_enum = true,
            .enum_val = result_desc.enumerable,
            .has_conf = true,
            .conf_val = result_desc.configurable,
            .has_get = true,
            .get_val = result_desc.value,
            .has_set = true,
            .set_val = result_desc.setter,
        } else .{
            .has_enum = true,
            .enum_val = result_desc.enumerable,
            .has_conf = true,
            .conf_val = result_desc.configurable,
            .has_val = true,
            .val = result_desc.value,
            .has_writ = true,
            .writ_val = result_desc.writable,
        };
        if (!isCompatiblePropertyDescriptor(completed_parsed, td)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap returned descriptor that is incompatible with property on the proxy target" }});
        }
        if (!result_desc.configurable and td.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for property which is configurable in the proxy target" }});
        }
        if (!result_desc.configurable and !result_desc.is_accessor and !result_desc.writable and !td.is_accessor and td.writable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'getOwnPropertyDescriptor' on proxy: trap reported non-configurable and non-writable for property which is writable in the proxy target" }});
        }
    }
    return result_desc;
}

fn proxyDefineProperty(rt: *Runtime, px_obj: *Object, k: object.Key, parsed: ParsedDesc, desc_obj: Value) Error!bool {
    var root_buf = [_]Value{ Value.fromObject(px_obj), desc_obj, parsed.val, parsed.get_val, parsed.set_val, keyToRootValue(k), .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "defineProperty");
    if (t.trap == null) return defineOwnPropertyParsed(rt, t.target, k, parsed, false);
    const prop_val = try keyToValue(rt, k);
    root_buf[6] = t.target;
    root_buf[7] = t.handler;
    root_buf[8] = prop_val;

    const trap_res = ops.toBoolean(try rt.callCallable(t.trap.?, t.handler, &.{ t.target, prop_val, desc_obj }));
    if (!trap_res) return false;

    const target_desc = try getOwnPropertyRaw(rt, t.target, k);
    const extensible_target = try isExtensibleValue(rt, t.target);
    const setting_non_conf = parsed.has_conf and !parsed.conf_val;

    if (target_desc == null) {
        if (!extensible_target) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for adding property to the non-extensible proxy target" }});
        }
        if (setting_non_conf) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining non-configurable property which is non-existent in the proxy target" }});
        }
    } else {
        const td = target_desc.?;
        if (!isCompatiblePropertyDescriptor(parsed, td)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining incompatible property" }});
        }
        if (setting_non_conf and td.configurable) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining non-configurable property which is configurable in the proxy target" }});
        }
        if (!td.is_accessor and !td.configurable and td.writable and parsed.has_writ and !parsed.writ_val) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'defineProperty' on proxy: trap returned truish for defining non-writable property which is writable in the proxy target" }});
        }
    }
    return true;
}

fn ownKeysAllValue(rt: *Runtime, target: Value) Error![]object.Key {
    var out: std.ArrayList(object.Key) = .empty;
    errdefer out.deinit(rt.gpa);
    switch (target.unpack()) {
        .object => |o| {
            if (o.kind == .proxy) return proxyOwnKeys(rt, o);
            const prop_names = try object.ownPropertyNames(rt, o);
            defer rt.gpa.free(prop_names);
            var idx_end: usize = 0;
            while (idx_end < prop_names.len and prop_names[idx_end] == .index) : (idx_end += 1) {}
            try out.appendSlice(rt.gpa, prop_names[0..idx_end]);
            if (o.kind == .array) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("length") });
            } else if (o.kind == .regexp) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("lastIndex") });
            }
            try out.appendSlice(rt.gpa, prop_names[idx_end..]);
            const syms = try object.ownSymbolKeys(rt, o, true);
            defer rt.gpa.free(syms);
            for (syms) |s| try out.append(rt.gpa, .{ .symbol = s });
        },
        .closure => |c| {
            if (!(c.meta != null and c.meta.?.length_deleted)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("length") });
            }
            if (!(c.meta != null and c.meta.?.name_deleted)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("name") });
            }
            if (hasAutoPrototype(c)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("prototype") });
            }
            const prop_names = try object.ownPropertyNamesClosure(rt, c);
            defer rt.gpa.free(prop_names);
            for (prop_names) |k| {
                if ((object.isNamed(k, "length") and !(c.meta != null and c.meta.?.length_deleted)) or
                    (object.isNamed(k, "name") and !(c.meta != null and c.meta.?.name_deleted))) continue;
                try out.append(rt.gpa, k);
            }
            const syms = try object.ownSymbolKeysClosure(rt, c, true);
            defer rt.gpa.free(syms);
            for (syms) |s| try out.append(rt.gpa, .{ .symbol = s });
        },
        .native => |n| {
            if (!rt.isNativePropDeleted(n, true)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("length") });
            }
            if (!rt.isNativePropDeleted(n, false)) {
                try out.append(rt.gpa, .{ .atom = try rt.heap.internAscii("name") });
            }
        },
        else => {},
    }
    return out.toOwnedSlice(rt.gpa);
}

fn keyInList(k: object.Key, list: []const object.Key) bool {
    for (list) |item| {
        switch (k) {
            .atom => |a| if (item == .atom and item.atom == a) return true,
            .index => |i| if (item == .index and item.index == i) return true,
            .symbol => |s| if (item == .symbol and item.symbol == s) return true,
        }
    }
    return false;
}

fn proxyOwnKeys(rt: *Runtime, px_obj: *Object) Error![]object.Key {
    var root_buf = [_]Value{ Value.fromObject(px_obj), .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "ownKeys");
    if (t.trap == null) return ownKeysAllValue(rt, t.target);
    root_buf[1] = t.target;
    root_buf[2] = t.handler;

    const trap_res = try rt.callCallable(t.trap.?, t.handler, &.{t.target});
    root_buf[2] = trap_res;
    if (!trap_res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned non-object" }});
    }

    const len_val = try object.get(rt, trap_res, try object.named(rt, "length"));
    const len_n = try toIntegerOrInfinity(rt, len_val);
    const len: usize = if (len_n <= 0) 0 else @intFromFloat(@min(len_n, @as(f64, @floatFromInt(rt.limits.max_stack_slots))));

    var out: std.ArrayList(object.Key) = .empty;
    errdefer out.deinit(rt.gpa);
    var seen: std.AutoHashMapUnmanaged(heap_mod.PropKey, void) = .empty;
    defer seen.deinit(rt.gpa);
    var out_roots: std.ArrayList(Value) = .empty;
    defer out_roots.deinit(rt.gpa);

    const ListRoot = struct {
        list: *const std.ArrayList(Value),
        fn mark(ctx: *anyopaque, h: *heap_mod.Heap) void {
            const self: *const @This() = @ptrCast(@alignCast(ctx));
            for (self.list.items) |v| h.markValue(v);
        }
    };
    var list_root: ListRoot = .{ .list = &out_roots };
    try rt.addRoots(.{ .ctx = &list_root, .mark = ListRoot.mark });
    defer rt.removeRoots(&list_root);

    for (0..len) |i| {
        const elem = try object.get(rt, trap_res, .{ .index = @intCast(i) });
        if (!elem.isString() and !elem.isSymbol()) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned non-string/symbol key" }});
        }
        const k = try object.key(rt, elem);
        const pk = try object.propKey(rt, k);
        const gop = try seen.getOrPut(rt.gpa, pk);
        if (gop.found_existing) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned duplicate entries" }});
        }
        try out.append(rt.gpa, k);
        try out_roots.append(rt.gpa, keyToRootValue(k));
    }

    const extensible_target = try isExtensibleValue(rt, t.target);
    const target_keys = try ownKeysAllValue(rt, t.target);
    defer rt.gpa.free(target_keys);

    for (target_keys) |tk| {
        const td = try getOwnPropertyRaw(rt, t.target, tk);
        const is_non_conf = if (td) |d| !d.configurable else false;
        if (is_non_conf and !keyInList(tk, out.items)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap result did not include non-configurable property" }});
        }
        if (!extensible_target and !keyInList(tk, out.items)) {
            return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap result did not include property of non-extensible target" }});
        }
    }
    if (!extensible_target and out.items.len != target_keys.len) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'ownKeys' on proxy: trap returned extra keys but proxy target is non-extensible" }});
    }
    return out.toOwnedSlice(rt.gpa);
}

pub const ProxyKeyFilter = enum { enum_strings, all_strings, enum_all };

pub fn proxyOwnKeysFiltered(rt: *Runtime, px_obj: *Object, filter: ProxyKeyFilter) Error![]object.Key {
    const keys = try proxyOwnKeys(rt, px_obj);
    defer rt.gpa.free(keys);

    const key_vals = try rt.gpa.alloc(Value, 1 + keys.len);
    defer rt.gpa.free(key_vals);
    key_vals[0] = Value.fromObject(px_obj);
    for (keys, key_vals[1..]) |k, *dst| dst.* = keyToRootValue(k);
    var roots: rt_mod.ValueRoots = .{ .values = key_vals };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(object.Key) = .empty;
    errdefer out.deinit(rt.gpa);
    for (keys) |k| {
        switch (filter) {
            .enum_strings => {
                if (k == .symbol) continue;
                const desc = (try proxyGetOwnPropertyDescriptor(rt, px_obj, k)) orelse continue;
                if (desc.enumerable) try out.append(rt.gpa, k);
            },
            .all_strings => {
                if (k == .symbol) continue;
                try out.append(rt.gpa, k);
            },
            .enum_all => {
                const desc = (try proxyGetOwnPropertyDescriptor(rt, px_obj, k)) orelse continue;
                if (desc.enumerable) try out.append(rt.gpa, k);
            },
        }
    }
    return out.toOwnedSlice(rt.gpa);
}

pub fn proxyOwnSymbolKeys(rt: *Runtime, px_obj: *Object, include_non_enum: bool) Error![]*heap_mod.Symbol {
    const keys = try proxyOwnKeys(rt, px_obj);
    defer rt.gpa.free(keys);

    const key_vals = try rt.gpa.alloc(Value, 1 + keys.len);
    defer rt.gpa.free(key_vals);
    key_vals[0] = Value.fromObject(px_obj);
    for (keys, key_vals[1..]) |k, *dst| dst.* = keyToRootValue(k);
    var roots: rt_mod.ValueRoots = .{ .values = key_vals };
    try roots.register(rt);
    defer roots.unregister(rt);

    var out: std.ArrayList(*heap_mod.Symbol) = .empty;
    errdefer out.deinit(rt.gpa);
    for (keys) |k| {
        if (k != .symbol) continue;
        if (!include_non_enum) {
            const desc = (try proxyGetOwnPropertyDescriptor(rt, px_obj, k)) orelse continue;
            if (!desc.enumerable) continue;
        }
        try out.append(rt.gpa, k.symbol);
    }
    return out.toOwnedSlice(rt.gpa);
}

pub fn callProxy(rt: *Runtime, px_obj: *Object, this_arg: Value, args: []const Value) Error!Value {
    try rt.checkNativeStack();
    if (!px_obj.kind.proxy.is_callable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not a function" }});
    }
    var root_buf = [_]Value{ Value.fromObject(px_obj), this_arg, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "apply");
    if (t.trap == null) return rt.callCallable(t.target, this_arg, args);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;

    const r = try realm(rt);
    const args_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(args_arr);
    try rt.heap.appendElements(args_arr, args);
    return rt.callCallable(t.trap.?, t.handler, &.{ t.target, this_arg, Value.fromObject(args_arr) });
}

pub fn callProxyConstruct(rt: *Runtime, px_obj: *Object, args: []const Value, new_target: Value) Error!Value {
    try rt.checkNativeStack();
    if (!px_obj.kind.proxy.is_constructable) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
    }
    var root_buf = [_]Value{ Value.fromObject(px_obj), new_target, .undefined, .undefined, .undefined };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const t = try getProxyTrap(rt, px_obj, "construct");
    if (t.trap == null) return constructWithNewTarget(rt, t.target, args, new_target);
    root_buf[2] = t.target;
    root_buf[3] = t.handler;

    const r = try realm(rt);
    const args_arr = try rt.heap.newArray(r.array_prototype);
    root_buf[4] = Value.fromObject(args_arr);
    try rt.heap.appendElements(args_arr, args);
    const res = try rt.callCallable(t.trap.?, t.handler, &.{ t.target, Value.fromObject(args_arr), new_target });
    if (!res.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "'construct' on proxy: trap returned non-object" }});
    }
    return res;
}

fn constructWithNewTarget(rt: *Runtime, target_in: Value, args: []const Value, new_target_in: Value) Error!Value {
    var target = target_in;
    var new_target = new_target_in;
    var extra_args: std.ArrayList(Value) = .empty;
    defer extra_args.deinit(rt.gpa);

    if (target.isClosure() and target.asClosure().impl == .bound) {
        const b = target.asClosure().impl.bound;
        if (sameValue(new_target, target)) new_target = b.target;
        if (b.bound_args.len > 0) {
            try extra_args.appendSlice(rt.gpa, b.bound_args);
            try extra_args.appendSlice(rt.gpa, args);
        }
        target = b.target;
    }
    const effective_args = if (extra_args.items.len > 0) extra_args.items else args;
    if (!isConstructor(target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "value is not a constructor" }});
    }
    if (target.isObject() and target.asObject().kind == .proxy) {
        return callProxyConstruct(rt, target.asObject(), effective_args, new_target);
    }
    if (target.isNative()) {
        if (!sameValue(new_target, target)) {
            const p = try object.get(rt, new_target, try object.named(rt, "prototype"));
            const po: ?*Object = if (p.isObject()) p.asObject() else null;
            if (target.asNative() == &object_global) {
                return Value.fromObject(try rt.heap.newObject(po orelse (try realm(rt)).object_prototype));
            }
            const res = try construct(rt, target, effective_args);
            if (po) |proto_obj| if (res.isObject()) rt.heap.storeObjectProto(res.asObject(), proto_obj);
            return res;
        }
        return construct(rt, target, effective_args);
    }
    return rt.constructClosure(target.asClosure(), effective_args, new_target);
}

fn requireReflectTarget(rt: *Runtime, v: Value, name: []const u8) Error!Value {
    if (!v.isObjectLike()) {
        return rt.throw(.TypeError, &.{ .{ .ascii = "Reflect." }, .{ .ascii = name }, .{ .ascii = " called on non-object" } });
    }
    return v;
}

fn reflectGet(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "get");
    const receiver = if (args.len >= 3) args[2] else target;
    var root_buf = [_]Value{ target, receiver };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, arg(args, 1));
    return object.getWithReceiver(rt, target, receiver, k);
}

fn reflectSet(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "set");
    const val = arg(args, 2);
    const receiver = if (args.len >= 4) args[3] else target;
    var root_buf = [_]Value{ target, val, receiver };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, arg(args, 1));
    return Value.fromBool(try object.setWithReceiver(rt, target, k, val, receiver, false));
}

fn reflectHas(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "has");
    var root_buf = [_]Value{target};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, arg(args, 1));
    return Value.fromBool(try object.has(rt, k, target));
}

fn reflectDeleteProperty(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "deleteProperty");
    var root_buf = [_]Value{target};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, arg(args, 1));
    return Value.fromBool(try object.delete(rt, target, k));
}

fn reflectOwnKeys(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "ownKeys");
    const r = try realm(rt);
    const out = try rt.heap.newArray(r.array_prototype);
    var root_buf = [_]Value{ target, Value.fromObject(out) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const keys = try ownKeysAllValue(rt, target);
    defer rt.gpa.free(keys);
    const key_vals = try rt.gpa.alloc(Value, keys.len);
    defer rt.gpa.free(key_vals);
    for (keys, key_vals) |k, *dst| dst.* = keyToRootValue(k);
    var key_roots: rt_mod.ValueRoots = .{ .values = key_vals };
    try key_roots.register(rt);
    defer key_roots.unregister(rt);

    for (keys) |k| {
        try rt.heap.appendElement(out, try keyToValue(rt, k));
    }
    return Value.fromObject(out);
}

fn reflectGetOwnPropertyDescriptor(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "getOwnPropertyDescriptor");
    var root_buf = [_]Value{target};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, arg(args, 1));
    const p = (try getOwnPropertyRaw(rt, target, k)) orelse return .undefined;
    return descriptorToObject(rt, p);
}

fn reflectDefineProperty(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "defineProperty");
    var root_buf = [_]Value{ target, arg(args, 2) };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);
    const k = try object.key(rt, arg(args, 1));
    const parsed = try parsePropertyDescriptor(rt, arg(args, 2));
    return Value.fromBool(try defineOwnPropertyParsed(rt, target, k, parsed, false));
}

fn reflectGetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "getPrototypeOf");
    return object.getPrototypeOfValue(rt, target);
}

fn reflectSetPrototypeOf(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "setPrototypeOf");
    return Value.fromBool(try setPrototypeOfValue(rt, target, arg(args, 1)));
}

fn reflectIsExtensible(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "isExtensible");
    return Value.fromBool(try isExtensibleValue(rt, target));
}

fn reflectPreventExtensions(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = try requireReflectTarget(rt, arg(args, 0), "preventExtensions");
    return Value.fromBool(try preventExtensionsValue(rt, target));
}

fn createListFromArrayLike(rt: *Runtime, list_val: Value) Error![]Value {
    if (!list_val.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "CreateListFromArrayLike called on non-object" }});
    }
    if (list_val.isObject() and list_val.asObject().kind == .array) {
        return rt.gpa.dupe(Value, list_val.asObject().kind.array.items);
    }
    var list_root = [_]Value{list_val};
    var lr: rt_mod.ValueRoots = .{ .values = &list_root };
    try lr.register(rt);
    defer lr.unregister(rt);

    const len_val = try object.get(rt, list_val, try object.named(rt, "length"));
    const len_n = try toIntegerOrInfinity(rt, len_val);
    const len: usize = if (len_n <= 0) 0 else @intFromFloat(@min(len_n, @as(f64, @floatFromInt(rt.limits.max_stack_slots))));
    const out = try rt.gpa.alloc(Value, len);
    errdefer rt.gpa.free(out);
    @memset(out, .undefined);
    var out_roots: rt_mod.ValueRoots = .{ .values = out };
    try out_roots.register(rt);
    defer out_roots.unregister(rt);

    for (0..len) |i| {
        out[i] = try object.get(rt, list_val, .{ .index = @intCast(i) });
    }
    return out;
}

fn reflectApply(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (!target.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reflect.apply requires a callable target" }});
    }
    const this_arg = arg(args, 1);
    var root_buf = [_]Value{ target, this_arg };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const arg_list = try createListFromArrayLike(rt, arg(args, 2));
    defer rt.gpa.free(arg_list);
    var arg_roots: rt_mod.ValueRoots = .{ .values = arg_list };
    try arg_roots.register(rt);
    defer arg_roots.unregister(rt);
    return rt.callCallable(target, this_arg, arg_list);
}

fn reflectConstruct(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const target = arg(args, 0);
    if (!isConstructor(target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reflect.construct requires a constructor target" }});
    }
    const new_target = if (args.len >= 3) args[2] else target;
    if (!isConstructor(new_target)) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Reflect.construct requires a constructor newTarget" }});
    }
    var root_buf = [_]Value{ target, new_target };
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const arg_list = try createListFromArrayLike(rt, arg(args, 1));
    defer rt.gpa.free(arg_list);
    var arg_roots: rt_mod.ValueRoots = .{ .values = arg_list };
    try arg_roots.register(rt);
    defer arg_roots.unregister(rt);
    return constructWithNewTarget(rt, target, arg_list, new_target);
}

// ---------------------------------------------------------------- Date (M50, D80)

const date_now: Native = .{ .name = "now", .length = 0, .call = dateNow };
const date_utc: Native = .{ .name = "UTC", .length = 7, .call = dateUtc };
const date_parse: Native = .{ .name = "parse", .length = 1, .call = dateParse };

const date_get_time: Native = .{ .name = "getTime", .length = 0, .call = dateGetTime };
const date_value_of: Native = .{ .name = "valueOf", .length = 0, .call = dateGetTime };
const date_get_timezone_offset: Native = .{ .name = "getTimezoneOffset", .length = 0, .call = dateGetTimezoneOffset };
const date_set_time: Native = .{ .name = "setTime", .length = 1, .call = dateSetTime };

const date_get_utc_full_year: Native = .{ .name = "getUTCFullYear", .length = 0, .call = dateGetUtcFullYear };
const date_get_utc_month: Native = .{ .name = "getUTCMonth", .length = 0, .call = dateGetUtcMonth };
const date_get_utc_date: Native = .{ .name = "getUTCDate", .length = 0, .call = dateGetUtcDate };
const date_get_utc_day: Native = .{ .name = "getUTCDay", .length = 0, .call = dateGetUtcDay };
const date_get_utc_hours: Native = .{ .name = "getUTCHours", .length = 0, .call = dateGetUtcHours };
const date_get_utc_minutes: Native = .{ .name = "getUTCMinutes", .length = 0, .call = dateGetUtcMinutes };
const date_get_utc_seconds: Native = .{ .name = "getUTCSeconds", .length = 0, .call = dateGetUtcSeconds };
const date_get_utc_milliseconds: Native = .{ .name = "getUTCMilliseconds", .length = 0, .call = dateGetUtcMilliseconds };

const date_set_utc_full_year: Native = .{ .name = "setUTCFullYear", .length = 3, .call = dateSetUtcFullYear };
const date_set_utc_month: Native = .{ .name = "setUTCMonth", .length = 2, .call = dateSetUtcMonth };
const date_set_utc_date: Native = .{ .name = "setUTCDate", .length = 1, .call = dateSetUtcDate };
const date_set_utc_hours: Native = .{ .name = "setUTCHours", .length = 4, .call = dateSetUtcHours };
const date_set_utc_minutes: Native = .{ .name = "setUTCMinutes", .length = 3, .call = dateSetUtcMinutes };
const date_set_utc_seconds: Native = .{ .name = "setUTCSeconds", .length = 2, .call = dateSetUtcSeconds };
const date_set_utc_milliseconds: Native = .{ .name = "setUTCMilliseconds", .length = 1, .call = dateSetUtcMilliseconds };

const date_get_full_year: Native = .{ .name = "getFullYear", .length = 0, .call = dateGetFullYear };
const date_get_month: Native = .{ .name = "getMonth", .length = 0, .call = dateGetMonth };
const date_get_date: Native = .{ .name = "getDate", .length = 0, .call = dateGetDate };
const date_get_day: Native = .{ .name = "getDay", .length = 0, .call = dateGetDay };
const date_get_hours: Native = .{ .name = "getHours", .length = 0, .call = dateGetHours };
const date_get_minutes: Native = .{ .name = "getMinutes", .length = 0, .call = dateGetMinutes };
const date_get_seconds: Native = .{ .name = "getSeconds", .length = 0, .call = dateGetSeconds };
const date_get_milliseconds: Native = .{ .name = "getMilliseconds", .length = 0, .call = dateGetMilliseconds };

const date_set_full_year: Native = .{ .name = "setFullYear", .length = 3, .call = dateSetFullYear };
const date_set_month: Native = .{ .name = "setMonth", .length = 2, .call = dateSetMonth };
const date_set_date: Native = .{ .name = "setDate", .length = 1, .call = dateSetDate };
const date_set_hours: Native = .{ .name = "setHours", .length = 4, .call = dateSetHours };
const date_set_minutes: Native = .{ .name = "setMinutes", .length = 3, .call = dateSetMinutes };
const date_set_seconds: Native = .{ .name = "setSeconds", .length = 2, .call = dateSetSeconds };
const date_set_milliseconds: Native = .{ .name = "setMilliseconds", .length = 1, .call = dateSetMilliseconds };

const date_to_iso_string: Native = .{ .name = "toISOString", .length = 0, .call = dateToIsoString };
const date_to_utc_string: Native = .{ .name = "toUTCString", .length = 0, .call = dateToUtcString };
const date_to_string: Native = .{ .name = "toString", .length = 0, .call = dateToString };
const date_to_date_string: Native = .{ .name = "toDateString", .length = 0, .call = dateToDateString };
const date_to_time_string: Native = .{ .name = "toTimeString", .length = 0, .call = dateToTimeString };
const date_to_json: Native = .{ .name = "toJSON", .length = 1, .call = dateToJson };
const date_to_primitive: Native = .{ .name = "[Symbol.toPrimitive]", .length = 1, .call = dateToPrimitive };

fn adjustTwoDigitYear(y: f64) f64 {
    if (!std.math.isFinite(y)) return y;
    const yi = @trunc(y);
    if (yi >= 0.0 and yi <= 99.0) return 1900.0 + yi;
    return y;
}

fn parseDateStringValue(s: *const heap_mod.String) f64 {
    if (s.units.len > 256) return std.math.nan(f64);
    var buf: [256]u8 = undefined;
    for (s.units, 0..) |u, i| {
        if (u > 0x7f) return std.math.nan(f64);
        buf[i] = @intCast(u);
    }
    return date.parse(buf[0..s.units.len]);
}

fn evalDateArgs(rt: *Runtime, args: []const Value, is_utc: bool) Error!f64 {
    const y_raw = try ops.toNumber(rt, arg(args, 0));
    const m = if (args.len > 1) try ops.toNumber(rt, args[1]) else 0.0;
    const dt = if (args.len > 2) try ops.toNumber(rt, args[2]) else 1.0;
    const h = if (args.len > 3) try ops.toNumber(rt, args[3]) else 0.0;
    const min = if (args.len > 4) try ops.toNumber(rt, args[4]) else 0.0;
    const s = if (args.len > 5) try ops.toNumber(rt, args[5]) else 0.0;
    const ms = if (args.len > 6) try ops.toNumber(rt, args[6]) else 0.0;
    const yr = adjustTwoDigitYear(y_raw);
    const final_date = date.makeDate(date.makeDay(yr, m, dt), date.makeTime(h, min, s, ms));
    return date.timeClip(if (is_utc) final_date else date.utcFromLocal(final_date));
}

fn dateCall(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    var buf: [128]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatToString(&buf, rt.nowMs())));
}

fn dateConstruct(rt: *Runtime, args: []const Value) Error!Value {
    const tv: f64 = if (args.len == 0)
        rt.nowMs()
    else if (args.len == 1) blk: {
        const v = args[0];
        if (v.isObject() and v.asObject().kind == .date) {
            break :blk date.timeClip(v.asObject().kind.date);
        }
        const pv = try object.toPrimitive(rt, v, .default);
        if (pv.isString()) {
            break :blk parseDateStringValue(pv.asString());
        }
        break :blk date.timeClip(try ops.toNumber(rt, pv));
    } else try evalDateArgs(rt, args, false);

    const r = try realm(rt);
    return Value.fromObject(try rt.heap.newDate(r.date_prototype, tv));
}

fn dateNow(rt: *Runtime, _: Value, _: []const Value) Error!Value {
    return Value.fromNumber(rt.nowMs());
}

fn dateUtc(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    return Value.fromNumber(try evalDateArgs(rt, args, true));
}

fn dateParse(rt: *Runtime, _: Value, args: []const Value) Error!Value {
    const s = try ops.toStringValue(rt, arg(args, 0));
    return Value.fromNumber(parseDateStringValue(s.asString()));
}

fn requireDate(rt: *Runtime, this: Value) Error!*Object {
    if (!this.isObject() or this.asObject().kind != .date) {
        return rt.throw(.TypeError, &.{.{ .ascii = "this is not a Date object" }});
    }
    return this.asObject();
}

fn dateGetTime(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    return Value.fromNumber(o.kind.date);
}

fn dateGetTimezoneOffset(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    return Value.fromNumber(date.timezoneOffsetMinutes(o.kind.date));
}

fn dateSetTime(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    const v = date.timeClip(try ops.toNumber(rt, arg(args, 0)));
    o.kind.date = v;
    return Value.fromNumber(v);
}

const DateField = enum { year, month, day, weekday, hour, minute, second, ms };

fn dateGetField(rt: *Runtime, this: Value, is_utc: bool, field: DateField) Error!Value {
    const o = try requireDate(rt, this);
    const t = o.kind.date;
    if (!std.math.isFinite(t)) return Value.fromNumber(std.math.nan(f64));
    const t_eff = if (is_utc) t else date.localTime(t);
    const d = date.decompose(t_eff) orelse return Value.fromNumber(std.math.nan(f64));
    return Value.fromNumber(switch (field) {
        .year => @floatFromInt(d.year),
        .month => @floatFromInt(d.month),
        .day => @floatFromInt(d.day),
        .weekday => @floatFromInt(d.weekday),
        .hour => @floatFromInt(d.hour),
        .minute => @floatFromInt(d.minute),
        .second => @floatFromInt(d.second),
        .ms => @floatFromInt(d.ms),
    });
}

fn dateGetUtcFullYear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .year);
}
fn dateGetUtcMonth(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .month);
}
fn dateGetUtcDate(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .day);
}
fn dateGetUtcDay(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .weekday);
}
fn dateGetUtcHours(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .hour);
}
fn dateGetUtcMinutes(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .minute);
}
fn dateGetUtcSeconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .second);
}
fn dateGetUtcMilliseconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, true, .ms);
}

fn dateGetFullYear(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .year);
}
fn dateGetMonth(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .month);
}
fn dateGetDate(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .day);
}
fn dateGetDay(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .weekday);
}
fn dateGetHours(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .hour);
}
fn dateGetMinutes(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .minute);
}
fn dateGetSeconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .second);
}
fn dateGetMilliseconds(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    return dateGetField(rt, this, false, .ms);
}

fn dateSetTimeFields(rt: *Runtime, this: Value, args: []const Value, is_utc: bool, start_idx: usize) Error!Value {
    const o = try requireDate(rt, this);
    const max_count = 4 - start_idx;
    var vals: [4]f64 = .{ 0, 0, 0, 0 };
    const n_args = @min(args.len, max_count);
    for (0..@max(n_args, 1)) |i| {
        vals[start_idx + i] = try ops.toNumber(rt, arg(args, i));
    }
    const t_raw = o.kind.date;
    if (!std.math.isFinite(t_raw)) return Value.fromNumber(std.math.nan(f64));
    const t = if (is_utc) t_raw else date.localTime(t_raw);
    const d = date.decompose(t) orelse return Value.fromNumber(std.math.nan(f64));
    const cur: [4]f64 = .{
        @floatFromInt(d.hour),
        @floatFromInt(d.minute),
        @floatFromInt(d.second),
        @floatFromInt(d.ms),
    };
    const h = if (start_idx <= 0 and 0 - start_idx < @max(n_args, 1)) vals[0] else cur[0];
    const m = if (start_idx <= 1 and 1 - start_idx < @max(n_args, 1)) vals[1] else cur[1];
    const s = if (start_idx <= 2 and 2 - start_idx < @max(n_args, 1)) vals[2] else cur[2];
    const ms = if (start_idx <= 3 and 3 - start_idx < @max(n_args, 1)) vals[3] else cur[3];
    const day_f = @floor(t / date.ms_per_day);
    const new_local = date.makeDate(day_f, date.makeTime(h, m, s, ms));
    const u = date.timeClip(if (is_utc) new_local else date.utcFromLocal(new_local));
    o.kind.date = u;
    return Value.fromNumber(u);
}

fn dateSetDateFields(rt: *Runtime, this: Value, args: []const Value, is_utc: bool, start_idx: usize) Error!Value {
    const o = try requireDate(rt, this);
    const max_count = 3 - start_idx;
    var vals: [3]f64 = .{ 0, 0, 0 };
    const n_args = @min(args.len, max_count);
    for (0..@max(n_args, 1)) |i| {
        vals[start_idx + i] = try ops.toNumber(rt, arg(args, i));
    }
    const t_raw = o.kind.date;
    const t = if (!std.math.isFinite(t_raw)) blk: {
        // Only setFullYear / setUTCFullYear (start_idx == 0) treats NaN as +0.0 per ES spec.
        if (start_idx != 0) return Value.fromNumber(std.math.nan(f64));
        break :blk 0.0;
    } else if (is_utc) t_raw else date.localTime(t_raw);
    const d = date.decompose(t) orelse return Value.fromNumber(std.math.nan(f64));
    const cur: [3]f64 = .{
        @floatFromInt(d.year),
        @floatFromInt(d.month),
        @floatFromInt(d.day),
    };
    const yr = if (start_idx <= 0 and 0 - start_idx < @max(n_args, 1)) vals[0] else cur[0];
    const mo = if (start_idx <= 1 and 1 - start_idx < @max(n_args, 1)) vals[1] else cur[1];
    const dt = if (start_idx <= 2 and 2 - start_idx < @max(n_args, 1)) vals[2] else cur[2];
    const tod = @as(f64, @floatFromInt(d.hour)) * date.ms_per_hour +
        @as(f64, @floatFromInt(d.minute)) * date.ms_per_minute +
        @as(f64, @floatFromInt(d.second)) * date.ms_per_second +
        @as(f64, @floatFromInt(d.ms));
    const new_local = date.makeDate(date.makeDay(yr, mo, dt), tod);
    const u = date.timeClip(if (is_utc) new_local else date.utcFromLocal(new_local));
    o.kind.date = u;
    return Value.fromNumber(u);
}

fn dateSetUtcFullYear(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, true, 0);
}
fn dateSetUtcMonth(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, true, 1);
}
fn dateSetUtcDate(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, true, 2);
}
fn dateSetUtcHours(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 0);
}
fn dateSetUtcMinutes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 1);
}
fn dateSetUtcSeconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 2);
}
fn dateSetUtcMilliseconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, true, 3);
}

fn dateSetFullYear(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, false, 0);
}
fn dateSetMonth(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, false, 1);
}
fn dateSetDate(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetDateFields(rt, this, args, false, 2);
}
fn dateSetHours(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 0);
}
fn dateSetMinutes(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 1);
}
fn dateSetSeconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 2);
}
fn dateSetMilliseconds(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    return dateSetTimeFields(rt, this, args, false, 3);
}

fn dateToIsoString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    if (!std.math.isFinite(o.kind.date)) {
        return rt.throw(.RangeError, &.{.{ .ascii = "Invalid time value" }});
    }
    var buf: [64]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatISO(&buf, o.kind.date)));
}

fn dateToUtcString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [64]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatUTC(&buf, o.kind.date)));
}

fn dateToString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [128]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatToString(&buf, o.kind.date)));
}

fn dateToDateString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [64]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatDateString(&buf, o.kind.date)));
}

fn dateToTimeString(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    const o = try requireDate(rt, this);
    var buf: [96]u8 = undefined;
    return Value.fromString(try rt.heap.ascii(date.formatTimeString(&buf, o.kind.date)));
}

fn dateToJson(rt: *Runtime, this: Value, _: []const Value) Error!Value {
    if (this.isUndefined() or this.isNull()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Cannot convert undefined or null to object" }});
    }
    var root_buf = [_]Value{this};
    var roots: rt_mod.ValueRoots = .{ .values = &root_buf };
    try roots.register(rt);
    defer roots.unregister(rt);

    const tv = try ops.toNumber(rt, this);
    if (!std.math.isFinite(tv)) return .null;
    const iso = try object.get(rt, this, try object.named(rt, "toISOString"));
    if (!iso.isFunction()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "toISOString is not a function" }});
    }
    return rt.callCallable(iso, this, &.{});
}

fn dateToPrimitive(rt: *Runtime, this: Value, args: []const Value) Error!Value {
    if (!this.isObjectLike()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Date.prototype[Symbol.toPrimitive] called on non-object" }});
    }
    const hint_val = arg(args, 0);
    if (!hint_val.isString()) {
        return rt.throw(.TypeError, &.{.{ .ascii = "Invalid hint" }});
    }
    const hint_units = hint_val.asString().units;
    if (eqlAscii(hint_units, "string") or eqlAscii(hint_units, "default")) {
        return object.ordinaryToPrimitive(rt, this, .string);
    }
    if (eqlAscii(hint_units, "number")) {
        return object.ordinaryToPrimitive(rt, this, .number);
    }
    return rt.throw(.TypeError, &.{.{ .ascii = "Invalid hint" }});
}

fn eqlAscii(units: []const u16, ascii: []const u8) bool {
    if (units.len != ascii.len) return false;
    for (units, ascii) |u, a| {
        if (u != a) return false;
    }
    return true;
}
