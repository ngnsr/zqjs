// The pool is deduplicated by value; strings are escaped in the listing.
print(1, 1, 1.0, 1e0, 'a', 'a', 'a', '\uD800', '"\\', 0.1 + 0.2, 1e21);
