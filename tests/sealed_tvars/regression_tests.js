// @flow

function no_missing_env_entry_for_delete() {
  declare var foo: {bar: string | void};
  delete foo.bar; // ok
  (foo.bar: void); // ok
}

function no_missing_env_entry_for_illegal_type_binding() {
  type A = number;
  type A = number; // error, but no MissingEnvEntry internal error.
}

function unresolved_class_self_tvar() {
  class C { } // no weird unresolved tvar error
}

exports.a = 1; // Read of exports points to a fully resolved exports type.

class MissingAnnotations {
  constructor () {
    return 42;
  }
  a;
  b: number = 42;
  c = 42;
  d = 42 + 42;
  e = (x: number): number => x;
  f = (x: number) => { }
  g = (x: number) => { return 42 }
  h() {}
  i(): number { return 42 }
  j() { return 42 }
  k = function (x: number) { }
}

class MoreMA {
  constructor(): void { }
}

class MoreMA2 {
  constructor() { }
}

function UnannotParams(x, {a, b}, ...y) { }

UnannotParams((x) => x);


type ModScope = string
declare module 'declared-module' {
  declare type ModScope = ModScopeExternal
}
type ModScopeExternal = number
(((42: any): ModScope): empty); // string ~> empty, not num ~> empty

declare module DeclaredModule2 {
  declare type ModScope2 = number
  declare type DependsOnModScope2 = ModScope2
}

declare var NonexistentType: ModScope2;

declare var AString: string;
const ResultOfError = -AString;

let UninitializedVar;

class ClassMethodThisAnnotations {
  method1(this: mixed) {
    (this: mixed);
  }
}

{
  let inexact = ({foo: 3}: {foo: number, ...});

  declare function inexactSpread<T>(x: T): {bar: 3, ...T};
  const inexact_spread_err = inexactSpread(inexact);
}

function TestArrayProvider() {
  var x = [];
  x[0] = 10;
}

{
  class MyClass<T> {
  }

  declare var c: MyClass;
}

interface InterfaceWithMethodThisAnnotation {
  test(this: mixed): void // ok
}

function anonymous_functions_this_type() {
  let foo1 = function () {}; // ok
  let foo2 = function (this: mixed) {}; // ok
  let foo3 = function () { this; }; // error: missing annot on this
  let foo4 = function (this: mixed) { this; }; // ok
}

function non_assigning_member_assigns() {
  declare var foo: {[string | number]: mixed};
  foo[1 + 2] = 1; // ok
  foo['1' + 2] = 3; // ok
  (1).toString = 3; // error: toString missing in number, but no missing env entry error
  declare var bar: {baz: number};
  bar.baz += 1; // ok
  bar.baz++; // ok
  (bar.baz: number); // ok
  bar.baz--; // ok
  (bar.baz: number); // ok
}

{
  var x: number = (x) => x;
}

{
  for (const x of x) {} // Error on second x, no underconstrained error on the first one.
}
