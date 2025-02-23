/**
 * @flow
 */

//////////////////////////////////
// == typeof <<class value>> == //
//////////////////////////////////

// MyClass1 is a runtime value, a constructor function
//
class MyClass1 {
  getNumber(): number { return 42; }
}

// a is an instance of MyClass1 - in runtime terms,
// an object produced by the MyClass1 constructor
// function.
//
var a: MyClass1 = new MyClass1();

// Following tests are errors which conflate the type
// of the class value itself with the type of its
// instances.

// Aside: it's worth staring at the following (correct)
// type annotations until they make sense:
//
//    MyClass1 : Class<MyClass1>
//    (new MyClass1()) : MyClass1
//
// The first says that the MyClass1 value (constructor
// function) has type Class<MyClass1> - the type of
// functions which produce instances of MyClass1 when
// called as a constructor.
//
// The second says that objects produced by the MyClass1
// constructor function have type MyClass1 - the type of
// instances of MyClass1.

// Error: assign the actual MyClass1 value to a  variable
// whose annotated type is of instances of MyClass1.
//
var b: MyClass1 = MyClass1;

class MyClass2 {
  getNumber1(): number { return 42; }
}

// The opposite error: assign an *instance* of MyClass2
// to a variable whose annotated type is the type of
// the class value (constructor function) MyClass2 itself.
//
var c: typeof MyClass2 = new MyClass2();

//////////////////////////////////////
// == typeof <<non-class value>> == //
//////////////////////////////////////

var numValue:number = 42;
var d: typeof numValue = 100;
var e: typeof numValue = 'asdf'; // Error: string ~> number

/////////////////////////////////
// == typeof <<type-alias>> == //
/////////////////////////////////

type numberAlias = number;

// This is an error because typeof takes a value, not
// a type, as an argument. However, the current error
// is suboptimal - just 'cannot resolve name'. TODO.
//
var f: typeof numberAlias = 42; // Error: 'typeof <<type-alias>>' makes no sense...

/**
 * Use of a non-class/non-function value in type annotation.
 * These provoke a specific error, not just the generic
 * "type is incompatible"
 */

 var Map = { "A": "this is A", "B": "this is B", "C": "this is C" };
 var keys: $Keys<Map> = "A";  // Error: ineligible value used in type anno

////////////////////////////////////////
// typeof <<variable declared later>> //
////////////////////////////////////////

declare var g: typeof h;
const h = 1;

(g: string); // error
(g: number);

declare var i: typeof j;
const j = { p: 1 };

(i.p: string); // error
(i.p: number);
