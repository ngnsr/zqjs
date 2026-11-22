// ASI across statements, return, break, postfix ++, do-while, EOF
let a = 1
let b = 2
a
++b
print(a, b)

function retBreak() {
  return
  42
}
print(retBreak())

let k = 0
do { k++ } while (k < 3) print(k)
