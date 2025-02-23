// @flow

function test(this: number | string, a: string, b: number): number {
  return this.length; // expect []/"" this
}

// args flow correctly into params
test.call("", "", 0);

// wrong this is an error
test.call(0, "", 0); // error: lookup `length` on Number

// not enough arguments is an error
test.call("", ""); // error: void ~> number

// mistyped arguments is an error
test.call("", "", ""); // error: string ~> number (2nd arg)
test.call("", 0, 0); // error: number ~> string (1st arg)

// resolve args array from tvar
function f(args: Array<(number | string)>) { test.call("", args[0], args[1]) } // error: args[0], args[1] mismatch
f(["", 0]); // OK
f(["", ""]); // OK
f([0, 0]); // OK

// expect 3 errors:
// - lookup length on Number (0 used as `this`)
// - number !~> string (param a)
// - string !~> number (param b)
(test.apply.call(test, 0, [0, 'foo']): number);

// args are optional
function test2(): number { return 0; }
(test2.call(): number);
(test2.call(""): number);

// callable objects
function test3(x: { (a: string, b: string): void }) {
  x.call(x, 'foo', 'bar'); // ok
  x.call(x, 'foo', 123); // error, number !~> string
}

let tests = [
  // string literal errors track use ops
  function() {
    function f(y: { x: "bar" }): void {}
    f({x: "foo"}); // error, "foo" !~> "bar"
  },

  // num literal errors track use ops
  function() {
    function f(y: { x: 123 }): void {}
    f({x: 234}); // error, 234 !~> 123
  },

  // bool literal errors track use ops
  function() {
    function f(y: { x: false }): void {}
    f({x: true}); // error, true !~> false
  },
];
