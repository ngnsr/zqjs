// M50 (D80): Date constructor, static methods, getters/setters, formatting, parsing, conversions.

// 1. Static lengths and properties
print(Date.length, Date.now.length, Date.UTC.length, Date.parse.length);
print(typeof Date.now(), Number.isFinite(Date.now()));
print(typeof Date(12345), !Number.isNaN(Date.parse(Date(12345))));

// 2. Date.UTC
print(Date.UTC(1970, 0), Date.UTC(1970, 0, 1, 0, 0, 0, 0));
print(Date.UTC(99, 0, 1), Date.UTC(0, 0, 1), Date.UTC(-1, 11, 31));
print(Date.UTC(2024, 1, 29), Date.UTC(1900, 1, 29), Date.UTC(2000, 1, 29));
print(Number.isNaN(Date.UTC(NaN, 0)), Number.isNaN(Date.UTC(2020, Infinity)));
print(Date.UTC(2020, 12, 32, 25, 61, 61, 1500));

// 3. Date.parse: ISO forms, date-only UTC, offsets, expanded years, RFC-2822 round-trip, invalid
print(Date.parse("1970"), Date.parse("1970-01"), Date.parse("1970-01-01"));
print(Date.parse("1970-01-01T00:00:00.000Z"));
print(Date.parse("1970-01-01T02:00:00+02:00"), Date.parse("1969-12-31T21:00:00-03:00"));
print(Date.parse("2020-06-15T12:34:56.78Z"), Date.parse("2020-06-15T24:00:00Z"));
print(Date.parse("+010000-01-01T00:00:00.000Z"), Date.parse("-000001-01-01T00:00:00.000Z"));
print(Date.parse("Thu, 01 Jan 1970 00:00:00 GMT"));
print(Date.parse(new Date(1700000000000).toUTCString()) === 1700000000000);
print(Number.isNaN(Date.parse("")), Number.isNaN(Date.parse("not-a-date")), Number.isNaN(Date.parse("2020-13-01")));

// 4. new Date(...) overloads
const dEpoch = new Date(0);
const dCopy = new Date(dEpoch);
print(dEpoch !== dCopy, dCopy.getTime(), dEpoch instanceof Date, Object.prototype.toString.call(dEpoch));
print(new Date("1970-01-01T00:00:00.000Z").getTime());
print(new Date(99, 0, 1).getFullYear(), new Date(0, 0, 1).getFullYear());
print(Number.isNaN(new Date(NaN).getTime()), Number.isNaN(new Date(8.64e15 + 1).getTime()));
print(new Date(-0).getTime(), Object.is(new Date(-0).getTime(), 0));

// 5. All UTC getters and setters
const d = new Date(0);
print(
    d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), d.getUTCDay(),
    d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds()
);
d.setUTCFullYear(2024, 1, 29);
d.setUTCHours(13, 14, 15, 167);
print(d.toISOString());
d.setUTCMonth(12, 2);
d.setUTCDate(0);
d.setUTCMinutes(65);
d.setUTCSeconds(70);
d.setUTCMilliseconds(1234);
print(d.toISOString());

// setUTCFullYear on NaN revives Invalid Date to +0.0 base
const dNan = new Date(NaN);
dNan.setUTCMonth(3);
print(Number.isNaN(dNan.getTime()));
dNan.setUTCFullYear(2025, 4, 5);
print(dNan.toISOString());

// 6. Local getters, setters, and getTimezoneOffset
const dLocal = new Date(2023, 5, 15, 10, 20, 30, 456);
print(
    dLocal.getFullYear(), dLocal.getMonth(), dLocal.getDate(),
    dLocal.getHours(), dLocal.getMinutes(), dLocal.getSeconds(), dLocal.getMilliseconds()
);
print(dLocal.getTimezoneOffset() === new Date(Date.UTC(2023, 5, 15, 10, 20, 30, 456)).getTimezoneOffset());
dLocal.setFullYear(2024);
dLocal.setMonth(11);
dLocal.setDate(25);
dLocal.setHours(8);
dLocal.setMinutes(9);
dLocal.setSeconds(10);
dLocal.setMilliseconds(111);
print(
    dLocal.getFullYear(), dLocal.getMonth(), dLocal.getDate(),
    dLocal.getHours(), dLocal.getMinutes(), dLocal.getSeconds(), dLocal.getMilliseconds()
);
dLocal.setTime(1700000000123);
print(dLocal.getTime());

// 7. Formatting: toISOString, toUTCString, toDateString, Invalid Date
print(new Date(0).toUTCString());
print(new Date(NaN).toUTCString(), new Date(NaN).toString(), new Date(NaN).toDateString(), new Date(NaN).toTimeString());
print(new Date(Date.UTC(10000, 0, 1)).toISOString());
print(new Date(Date.UTC(-1, 0, 1)).toISOString());
print(new Date(8.64e15).toISOString(), new Date(-8.64e15).toISOString());
try {
    new Date(NaN).toISOString();
    print("FAIL");
} catch (e) {
    print(e instanceof RangeError, e.name);
}

// 8. toJSON + JSON.stringify
print(new Date(0).toJSON(), new Date(NaN).toJSON());
print(JSON.stringify({ t: new Date(0), bad: new Date(NaN) }));
print(Date.prototype.toJSON.call({ valueOf() { return 1; }, toISOString() { return "custom"; } }));
print(Date.prototype.toJSON.call({ valueOf() { return NaN; }, toISOString() { return "nope"; } }));

// 9. [Symbol.toPrimitive], d1 - d2, d1 + ""
const d1 = new Date(1000);
const d2 = new Date(250);
print(d1 - d2, d1.valueOf(), Number(d1));
print(typeof (d1 + ""), (d1 + "") === d1.toString());
print(d1[Symbol.toPrimitive]("number") === 1000);
print(d1[Symbol.toPrimitive]("string") === d1.toString());
print(d1[Symbol.toPrimitive]("default") === d1.toString());
for (const badHint of [undefined, null, 42, "boolean", ""]) {
    try {
        d1[Symbol.toPrimitive](badHint);
        print("FAIL");
    } catch (e) {
        print(e instanceof TypeError);
    }
}

// 10. Non-Date receiver TypeError
for (const fn of [
    Date.prototype.getTime,
    Date.prototype.valueOf,
    Date.prototype.getUTCFullYear,
    Date.prototype.getFullYear,
    Date.prototype.setTime,
    Date.prototype.setUTCFullYear,
    Date.prototype.toISOString,
    Date.prototype.toUTCString,
    Date.prototype.toString,
]) {
    try {
        fn.call({});
        print("FAIL");
    } catch (e) {
        print(e instanceof TypeError);
    }
}
