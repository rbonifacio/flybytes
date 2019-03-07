module lang::flybytes::Decompiler

extend lang::flybytes::Disassembler;

import Exception;
import String;
import List; 
 
@synopsis{Decompile a JVM classfile to Flybytes ASTs, recovering statement and expression structures.}
Class decompile(loc classFile) throws IO { 
  cls = disassemble(classFile);
  
  return cls[methods = [decompile(m) | m <- cls.methods]];
}
 
Method decompile(loc classFile, str methodName) {
  cls = disassemble(classFile);
  if (Method m <- cls.methods, m.desc?, m.desc.name?, m.desc.name == methodName) {
    return decompile(m);
  }
  
  throw "no method named <methodName> exists in this class: <for (m <- cls.methods, m.desc?, m.desc.name?) {><m.desc.name> <}>";
}

Method decompile(Method m:method(_, _, [asm(list[Instruction] instrs)])) {  
  withoutLines = lines(instrs);
  withJumps = jumps(withoutLines);
  withoutLabels = labels(withJumps);
  withExp = exprs(withoutLabels);
  withStat = stmts(withExp);
  withDecls = decls(withStat, m.formals);
  done = visit ([asm(withDecls)]) {
    case list[Stat] l => clean(l)
  }
  return m[block=[asm(withDecls)]];
  //return m[block=done];  
}

Method decompile(Method m:static([asm(list[Instruction] instrs)])) {  
  withoutLines = lines(instrs);
  withJumps = jumps(withoutLines);
  withoutLabels = labels(withJumps);
  withExp = exprs(withoutLabels);
  withStat = stmts(withExp);
  done = visit ([asm(withStat)]) {
    case list[Stat] l => clean(l)
  }
  //return m[block=[asm(withStat)]];  
  return m[block=done];
}

Method decompile(Method m) = m when \abstract in m.modifiers; 

// LINES: 
data Instruction(int line = -1);
data Exp(int line = -1);
data Stat(int line = -1);

@synopsis{set the information from LINENUMBER instructions to all following instructions as a field, and removes the instruction}
list[Instruction] lines([*Instruction pre, LINENUMBER(lin, lab), Instruction next, *Instruction post])
  = lines([*pre, next[line=lin], *lines([LINENUMBER(lin, lab), *post])])
  when !(next is LINENUMBER);

list[Instruction] lines([*Instruction pre, LINENUMBER(_, _), Instruction next:LINENUMBER(_,_), *Instruction post])
  = lines([*pre, *lines([next, *post])]);
  
list[Instruction] lines([*Instruction pre, LINENUMBER(_, _)])
  = pre;  

default list[Instruction] lines(list[Instruction] l) = l;
  
// JUMP LABEL PROTECTION
data Instruction(bool jumpTarget = false);

@synopsis{marks jump targets with the jumpTarget=true field, for later use by label removal and detection of structured statements}
list[Instruction] jumps([*Instruction pre, Instruction jump:/IF|GOTO|IFNULL|IFNONNULL|JSR/(str l1), *Instruction mid, LABEL(l1, jumpTarget=false), *Instruction post]) 
  = jumps([*pre, jump, *mid, LABEL(l1, jumpTarget=true), *post]);  
  
list[Instruction] jumps([*Instruction pre, LABEL(str l1, jumpTarget=false), *Instruction mid, Instruction jump:/IF|GOTO|IFNULL|IFNONNULL|JSR/(l1), *Instruction post]) 
  = jumps([*pre, LABEL(l1, jumpTarget=true), *mid, jump, *post]);    

list[Instruction] jumps([*Instruction pre, Instruction s:TABLESWITCH(_,_,str def,_), *Instruction mid, LABEL(def, jumpTarget=false), *Instruction post]) 
  = jumps([*pre, s, *mid, LABEL(def, jumpTarget=true), *post]);              

// This one breaks the interpreter's list matcher if `cl` is introduces in the nested list under the TABLESWITCH node before it is used in the LABEL:
list[Instruction] jumps([*Instruction pre, Instruction s:TABLESWITCH(_,_,_,[*_, cl, *_]), *Instruction mid, LABEL(str cl, jumpTarget=false), *Instruction post]) 
  = jumps([*pre, s, *mid, LABEL(cl, jumpTarget=true), *post]);

list[Instruction] jumps([*Instruction pre, LABEL(str \start), *Instruction block, LABEL(str \end), *Instruction mid1, LABEL(str handler), *Instruction mid2, TRYCATCH(Type typ, \start, end, handler), *Instruction post]) 
  = jumps([*pre, TRYCATCH(typ, \start, end, handler), LABEL(\start, jumpTarget=true), *block, LABEL(\end, jumpTarget=true), *mid1, LABEL(handler, jumpTarget=true), *mid2, *post]);

default list[Instruction] jumps(list[Instruction] l) = l;
 
// LABEL REMOVAL
@synopsis{removes all labels which are not jump targets}
list[Instruction] labels([*Instruction pre,  LABEL(_, jumpTarget=false), *Instruction post]) 
  = [*pre, *labels(post)];  

default list[Instruction] labels(list[Instruction] l) = l;

// LOCAL VARIABLES DECLARATIONS

// remove the implicit "this"
list[Instruction] decls([*Instruction pre, LOCALVARIABLE("this", _, _, _, _), *Instruction post], list[Formal] formals)
  = decls([*pre, *post], formals);
  
// remove the duplicate declaration of the method formal parameters  
list[Instruction] decls([*Instruction pre, LOCALVARIABLE(str name, Type typ, _, _, _), *Instruction post], [*pref,  var(\typ, name), *postf])
  = decls([*pre, *post], [*pref, *postf]);
  
// for everything else introduce a declaration:
list[Instruction] decls([*Instruction pre, LOCALVARIABLE(str name, Type typ, _, _, _), *Instruction post], [])  
  = decls([stat(decl(typ, name)), *decls([*pre, *post], [])], []);

// clean up by inlining initial expressions
list[Instruction] decls([*Instruction pre, stat(decl(typ, name)), *Instruction mid, stat(store(name, e)), *Instruction post], [])
  = decls([*pre, stat(decl(typ, name, init=e)), *mid, *post], [])
  when mid == [] || all(i <- mid, stat(decl(_,_)) := i)
  ;

default list[Instruction] decls(list[Instruction] l, list[Formal] _) = l;

// STATEMENTS

@synopsis{recovers structured statements}  

list[Instruction] stmts([*Instruction pre, exp(a), exp(b), /IF_[IA]CMP<op:EQ|NE|LT|GE|LE>/(str l1), *Instruction thenPart, LABEL(l1), *Instruction post]) 
  = stmts([*pre, stat(\if(invertedCond(op)(a, b), [asm(stmts(thenPart))])), LABEL(l1), *post]);

list[Instruction] stmts([*Instruction pre, exp(a), /IF<op:NULL|NONNULL|EQ|NE|LT|GT|LE>/(l1), *Instruction thenPart, LABEL(l1), *Instruction post]) 
  = stmts([*pre, stat(\if(invertedCond(op)(a, const(byte(), 0)), [asm(stmts(thenPart))])), *post]);
  
list[Instruction] stmts([*Instruction pre, stat(\if(c ,[asm([*Instruction thenPart, GOTO(l1)])])), LABEL(_), *Instruction elsePart, LABEL(l1), *Instruction post]) 
  = stmts([*pre, stat(\if(c, [asm(stmts(thenPart))],[asm(stmts(elsePart))])), LABEL(l1), *post]);

list[Instruction] stmts([*Instruction pre, stat(\return(Exp e)), NOP(), *Instruction post]) 
  = stmts([*pre, stat(\return(e)), *post]);

list[Instruction] stmts([*Instruction pre, stat(\return(Exp e)), ATHROW(), *Instruction post]) 
  = stmts([*pre, stat(\return(e)), *post]);
  
// SWITCH; this  complex statement is parsed in a number of recursive (data-dependent) steps. 

 // to store intermediately recognized case blocks we augment the TABLESWITCH with this information:
data Instruction(lrel[Case, str] cases = []); 

// we first fold in pairwise each case, using their labels to "bracket" their instructions, this depend on list matching being lazy (non-eager). 
list[Instruction] stmts([*Instruction pre, TABLESWITCH(int from, int to, str def, list[str] keys, cases=cl), LABEL(str c1), *Instruction case1, LABEL(str c2), *Instruction post]) 
  = stmts([*pre, TABLESWITCH(from, to, def, keys, cases=cl+[<\case(size(before) + from, [asm(case1)]), c1>]), LABEL(c2), *post]) 
  when [*before, c1, *_] := keys, c2 in keys
  ;
  
// when the number of cases is odd, we have a single final case to fold in, which is always bracketed by the default label:  
list[Instruction] stmts([*Instruction pre, TABLESWITCH(int from, int to, str def, list[str] keys, cases=cl), LABEL(str c1), *Instruction case1, LABEL(def), *Instruction post]) 
  = stmts([*pre, TABLESWITCH(from, to, def, keys, cases=cl+[<\case(size(before) + from, [asm(case1)]), c1>]), LABEL(def), *post]) 
  when  [*before, c1, *after] := keys;
  
// now we can lift the TABLESWITCH statement to the switch statement (signalled by the empty case list and the immediate following of the def label)
// Note this case only works if there is at least one break label to bracket the default case with:  
list[Instruction] stmts([*Instruction pre, exp(a), TABLESWITCH(int from, _, str def, list[str] keys, cases=lrel[Case, str] cl), LABEL(def), *Instruction defCase, LABEL(str brk), *Instruction post]) 
  = stmts([*pre, stat(\switch(a, breaks([*sharedCases(c.key, lab, keys, from), c | <c, lab> <- cl] + sharedDefaults(def, keys, from) + [\default([asm(defCase)])], brk))), LABEL(def), *post])
  when /GOTO(brk) := cl
  ;

// or there is no default case, in which case the breaks go to the def label
list[Instruction] stmts([*Instruction pre, exp(a), TABLESWITCH(int from, _, str def, list[str] keys, cases=cl), LABEL(def), *Instruction post]) 
  = stmts([*pre, stat(\switch(a, breaks([*sharedCases(c.key, lab, keys, from) , c | <c,lab> <- cl], def))), LABEL(def), *post]);  

// shared cases are keys which do not have a corresponding unique block in the list of statements after the SWITCH jump: `case 1: case 2: block`  
list[Case] sharedCases(int key, str lab, list[str] keys, int offset)
  = [\case(pos,[]) | [*before, lab, *_] := keys, int pos := size(before) + offset, pos != key];
  
list[Case] sharedDefaults(str lab, list[str] keys, int offset)
  = [\case(pos,[]) | [*before, lab, *_] := keys, int pos := size(before) + offset];  
 
// Try/catch statements are also complex. They are recovered in a similar fashion as SWITCH,
// since the generated code for the catch blocks is laid out similarly to a set of case statements.
// Pre-work has been done by the `jumps` function, which moved every TRYCATCH Instruction next to 
// the start label of the block that is guarded by the TRYCATCH

data Instruction(list[Handler] handlers=[]);

// first we fold in catch blocks, starting from the left and using the next block as a bracket:
list[Instruction] stmts(
  [
   *Instruction pre, 
   TRYCATCH(Type \typ1, str from, str to, str handler1, handlers=hs),  
   TRYCATCH(Type \typ2, from, to, str handler2), 
   *Instruction block,
   LABEL(to),
   Instruction jump, // RETURN GOTO OR BREAK
   LABEL(handler1),
   exp(load(str var)), // This was rewritten from a ASTORE(ind) earlier by the `jump` function
   *Instruction catch1,
   LABEL(handler2),
   *Instruction post
  ]) 
  = stmts([*pre, TRYCATCH(\typ2, from, to, handler2, handlers=hs+[\catch(\typ1, var, [asm(catch1)])]), *block, LABEL(to), jump, LABEL(handler2), *post]);  

// multi-catch does not exist in Flybytes, so we have to duplicate the handlers.
// this temporary constructor encodes the instruction to make the duplication later
data Stat = multiCatchHandler();

list[Instruction] stmts(
  [
   *Instruction pre, 
   TRYCATCH(Type \typ1, str from, str to, str handler1, handlers=hs),  
   TRYCATCH(Type \typ2, from, to, handler1), 
   *Instruction block,
   LABEL(to),
   Instruction jump, 
   LABEL(handler1),
   exp(load(str var)), // This was rewritten from a ASTORE(ind) earlier by the `jump` function
   *Instruction post
  ]) 
  = stmts([ 
   *pre, 
   TRYCATCH(\typ2, from, to, handler1, handlers=hs+[\catch(typ1, var, [multiCatchHandler()])]),  
   *block,
   LABEL(to),
   jump, 
   LABEL(handler1),
   exp(load(var)),
   *post
   ]);  

// we detect the end of the final handler by seeing if anybody inside the try block or the 
// previous handlers GOTO's to the label just after the final handler.   
list[Instruction] stmts(
  [*Instruction pre, 
   TRYCATCH(Type \typ1, str from, str to, str handler1, handlers=hs),
   LABEL(from),
   *Instruction block,  
   LABEL(to),
   GOTO(\join), // jump to after the final handler
   LABEL(handler1),
   exp(load(str var)), // This was rewritten from a ASTORE(ind) earlier by the `jump` function
   *Instruction catch1,
   LABEL(\join),
   *Instruction post
  ]) 
  = stmts([*pre, stat(\try([asm(stmts(exprs(tryJoins(block, \join))))],tryJoins([*hs,\catch(\typ1, var, [asm(stmts(catch1))])], \join))), LABEL(\join), *post])
  ; 
  
list[Instruction] stmts(
  [*Instruction pre, 
   TRYCATCH(Type \typ1, str from, str to, str handler1, handlers=hs),
   LABEL(from),
   *Instruction block,  
   LABEL(to),
   Instruction jump, // no jump to after the final handler, look elsewhere
   LABEL(handler1),
   exp(load(str var)),
   *Instruction catch1,
   LABEL(str \join),
   *Instruction post
  ]) 
  = stmts([*pre, stat(\try([asm(stmts(exprs(tryJoins([*block, jump], \join))))],tryJoins([*hs,\catch(\typ1, var, [asm(stmts(catch1))])], \join))), LABEL(\join), *post])
  // find any GOTO jump to after the final handler:
  when GOTO(_) !:= jump, /GOTO(\join) := block || /GOTO(\join) := hs || /GOTO(\join) := catch1
  ;  
    
 // but if there is no such GOTO, then we do not know where the final catch block ends.
// however, the theory is that if no such GOTO exists, then the code after the try would only 
// be reachable by falling through the final catch block anyway.
list[Instruction] stmts(
  [
   *Instruction pre, 
   TRYCATCH(Type \typ1, str from, str to, str handler1, handlers=hs),
   LABEL(from),
   *Instruction block,  
   LABEL(to),
   Instruction jump, // RETURN OR BREAK
   LABEL(handler1),
   exp(load(str var)),
   *Instruction post
  ]) 
  = stmts([*pre, stat(\try([asm(stmts(exprs([*block, jump])))],[*hs,\catch(\typ1, var, [/*temp empty*/])])), *post])
  when /GOTO(_) !:= hs, /GOTO(_) !:= block, GOTO(_) !:= jump
  ;    
  
// duplicate the multi-handler blocks now    
list[Instruction] stmts([*Instruction pre, stat(\try(list[Stat] block, [*Handler preh, \catch(Type typ1, str var, [multiCatchHandler()]), \catch(Type typ2, var, list[Stat] catch1), *Handler posth])), *Instruction post])
  = stmts([*pre, stat(\try(block, [*preh, \catch(typ1, var, catch1), \catch(typ2, var, catch1), *posth])), *post]);
    
// recover boolean conditions  
list[Instruction] stmts([*Instruction pre, stat(\if(eq(Exp a, const(Type _, 0)), thenPart, elsePart)), *Instruction post]) 
  = stmts([*pre, stat(\if(neg(a), thenPart, elsePart)), *post]);
  
list[Instruction] stmts([*Instruction pre, stat(\if(eq(Exp a, const(Type _, 0)), thenPart)), *Instruction post]) 
  = stmts([*pre, stat(\if(neg(a), thenPart)), *post]);
  
list[Instruction] stmts([*Instruction pre, stat(\for(init, eq(Exp a, const(Type _, 0)), next, block)), *Instruction post]) 
  = stmts([*pre, stat(\for(init, neg(a), next, block)), *post]);  
  
list[Instruction] stmts([*Instruction pre, stat(\if(ne(Exp a, const(Type _, 0)), thenPart, elsePart)), *Instruction post]) 
  = stmts([*pre, stat(\if(a, thenPart, elsePart)), *post]);
  
list[Instruction] stmts([*Instruction pre, stat(\if(ne(Exp a, const(Type _, 0)), thenPart)), *Instruction post]) 
  = stmts([*pre, stat(\if(a, thenPart)), *post]);   

list[Instruction] stmts([*Instruction pre, stat(\for(init, ne(Exp a, const(Type _, 0)), next, block)), *Instruction post]) 
  = stmts([*pre, stat(\for(init, a, next, block)), *post]);  
   
  
// expressions which will not be consumed are expression statements:
list[Instruction] stmts([*Instruction pre, exp(e), stat(s), *Instruction post]) 
  = stmts([*pre, stat(do(e)), stat(s), *post]);
  
list[Instruction] stmts([*Instruction pre, exp(e)]) 
  = stmts([*pre, stat(do(e))]);  

list[Instruction] stmts([*Instruction pre, GOTO(str body), LABEL(str cond), *Instruction c, LABEL(body), exp(a), exp(b), /IF_[IA]CMP<op:EQ|NE|LT|GE|LE>/(cond), *Instruction post]) 
  = stmts([*pre, stat(\while(condOp(op)(a,b),[asm(stmts(c))])), *post]);
  
list[Instruction] stmts([*Instruction pre, GOTO(str body), LABEL(str cond), *Instruction c, LABEL(body), exp(a), /IF<op:NULL|NONNULL|EQ|NE|LT|GT|LE>/(cond), *Instruction post]) 
  = stmts([*pre, stat(\while(condOp(op)(a, const(byte(), 0)),[asm(stmts(c))])), *post]);  

list[Instruction] stmts([*Instruction pre, LABEL(str body), *Instruction c, exp(a), exp(b), /IF_[IA]CMP<op:EQ|NE|LT|GE|LE>/(body), *Instruction post]) 
  = stmts([*pre, stat(\doWhile([asm(stmts(c))], condOp(op)(a,b))), *post]);

list[Instruction] stmts([*Instruction pre, LABEL(str body), *Instruction c, exp(a), /IF<op:NULL|NONNULL|EQ|NE|LT|GT|LE>/(body), *Instruction post]) 
  = stmts([*pre, stat(\doWhile([asm(stmts(c))], condOp(op)(a, const(byte(), 0)))), *post]);
          
list[Instruction] stmts([*Instruction pre, stat(first:store(str name,_)), stat(\while(c, [asm([*Instruction b, stat(next:/store|incr/(name,_))])])), *Instruction post]) 
  = stmts([*pre, stat(\for([first], c, [next], [asm(stmts(b))])), *post]);
  
// fold in multiple inits and nexts in for loop  
list[Instruction] stmts([*Instruction pre, stat(first:store(str name, _)), stat(\for(firsts, c, nexts, [asm([*Instruction b, stat(next:/store|incr/(name,_))])])), *Instruction post]) 
  = stmts([*pre, stat(\for([first,*firsts], c, [next, *nexts], [asm(stmts(b))])), *post]);     
                                              
default list[Instruction] stmts(list[Instruction] st) = st;

// VARIABLES

@synopsis{recovers the structure of expressions and very basic statements}
list[Instruction] exprs([*Instruction pre, exp(e), /[AIFLD]STORE/(int var), *Instruction mid, Instruction lv:LOCALVARIABLE(str name, _, _, _, var), *Instruction post]) 
  = exprs([*pre, stat(store(name, e)), *mid, lv, *post]);
  
// stores the name of catch clause variables at the position of the handler:  
list[Instruction] exprs([*Instruction pre, tc:TRYCATCH(_,  _, _, handler), *Instruction other, LABEL(str handler), ASTORE(int var), *Instruction mid, Instruction lv:LOCALVARIABLE(str name, _, _, _, var), *Instruction post]) 
  = exprs([*pre, tc, *other, LABEL(handler), exp(load(name)) /* temporary */, *mid, lv, *post]);  
  
list[Instruction] exprs([*Instruction pre, IINC(int var, int i), *Instruction mid, Instruction lv:LOCALVARIABLE(str name, _, _, _, var), *Instruction post]) 
  = exprs([*pre, stat(incr(name, i)), *mid, lv, *post]);
    
list[Instruction] exprs([*Instruction pre, /[AIFLD]LOAD/(int var), *Instruction mid, Instruction lv:LOCALVARIABLE(str name, _, _, _, var), *Instruction post]) 
  = exprs([*pre, exp(load(name)), *mid, lv, *post]);
  
// EXPRESSIONS

list[Instruction] exprs([*Instruction pre, exp(a), /[ILFDA]RETURN/(), *Instruction post]) 
  = exprs([*pre, stat(\return(a)), *post]);
  
list[Instruction] exprs([*Instruction pre, exp(a), ATHROW(), *Instruction post]) 
  = exprs([*pre, stat(\throw(a)), *post]);  

list[Instruction] exprs([*Instruction pre, exp(rec), exp(arg), PUTFIELD(cls, name, typ), *Instruction post]) 
  = exprs([*pre, stat(putField(cls, rec, typ, name, arg)), *post]);
              
list[Instruction] exprs([*Instruction pre, RETURN(), *Instruction post]) 
  = exprs([*pre, stat(\return()), *post]);

list[Instruction] exprs([*Instruction pre, NOP(), *Instruction post]) 
  = exprs([*pre, *exprs(post)]);

list[Instruction] exprs([*Instruction pre, ACONST_NULL(), *Instruction post]) 
  = exprs([*pre, exp(null()), *exprs(post)]);
  
list[Instruction] exprs([*Instruction pre, /<t:[IFLD]>CONST_<i:[0-5]>/(), *Instruction post]) 
  = exprs([*pre, exp(const(typ(t), toInt(i))), *exprs(post)]);

list[Instruction] exprs([*Instruction pre, exp(a), ARRAYLENGTH(), *Instruction post]) 
  = exprs([*pre, exp(alength(a)), *exprs(post)]);
  
list[Instruction] exprs([*Instruction pre, exp(a), /[IFLD]NEG/(), *Instruction post]) 
  = exprs([*pre, exp(neg(a)), *exprs(post)]);

list[Instruction] exprs([*Instruction pre, exp(Exp a), exp(Exp b), /[LFDI]<op:(ADD|SUB|MUL|DIV|REM|SHL|SHR|AND|OR|XOR|ALOAD)>/(), *Instruction post]) 
  = exprs([*pre, exp(binOp(op)(a,b)), *exprs(post)]);

list[Instruction] exprs([*Instruction pre, exp(Exp r), *Instruction args, INVOKEVIRTUAL(cls, methodDesc(ret, name, formals), _), *Instruction post]) 
  = exprs([*pre, exp(invokeVirtual(cls, r, methodDesc(ret, name, formals), [e | exp(Exp e) <- args])), *post])
  when (args == [] && formals == []) || all(a <- args, a is exp), size(args) == size(formals);

list[Instruction] exprs([*Instruction pre, exp(Exp r), *Instruction args, INVOKEINTERFACE(cls, methodDesc(ret, name, formals), _), *Instruction post]) 
  = exprs([*pre, exp(invokeInterface(cls, r, methodDesc(ret, name, formals), [e | exp(e) <- args])), *post])
  when (args == [] && formals == []) || all(a <- args, a is exp), size(args) == size(formals);

list[Instruction] exprs([*Instruction pre, exp(Exp r), *Instruction args, INVOKESPECIAL(cls, methodDesc(ret, name, formals), _), *Instruction post]) 
  = exprs([*pre, exp(invokeSpecial(cls, r, methodDesc(ret, name, formals), [e | exp(e) <- args])), *post])
  when (args == [] && formals == []) || all(a <- args, a is exp), size(args) == size(formals);
  
list[Instruction] exprs([*Instruction pre, NEW(typ), DUP(), *Instruction args, INVOKESPECIAL(cls, constructorDesc(formals), _), *Instruction post]) 
  = exprs([*pre, exp(newInstance(typ, constructorDesc(formals), [e | exp(e) <- args])), *post])
  when (args == [] && formals == []) || all(a <- args, a is exp), size(args) == size(formals);  

list[Instruction] exprs([*Instruction pre, exp(load("this")), *Instruction args, INVOKESPECIAL(cls, constructorDesc(formals), _), *Instruction post]) 
  = exprs([*pre, stat(invokeSuper(constructorDesc(formals), [e | exp(e) <- args])), *post])
  when (args == [] && formals == []) || all(a <- args, a is exp), size(args) == size(formals);

list[Instruction] exprs([*Instruction pre, *Instruction args, INVOKESTATIC(cls, methodDesc(ret, name, formals), _), *Instruction post]) 
  = exprs([*pre, exp(invokeStatic(cls, methodDesc(ret, name, formals), [e | exp(e) <- args])), *post])
  when (args == [] && formals == []) || all(a <- args, a is exp), size(args) == size(formals);
    
list[Instruction] exprs([*Instruction pre, exp(const(integer(), int arraySize)), ANEWARRAY(typ), *Instruction elems, *Instruction post]) 
  = exprs([*pre, exp(newArray(typ, [e | [*_, DUP(), exp(const(integer(), _)), exp(e), AASTORE(), *_] := elems])), *post])
  when size(elems) == 4 * arraySize;

list[Instruction] exprs([*Instruction pre, GETSTATIC(cls, name, typ), *Instruction post]) 
  = exprs([*pre, exp(getStatic(cls, typ, name)), *post]);
        
list[Instruction] exprs([*Instruction pre, exp(e), PUTSTATIC(cls, name, typ), *Instruction post]) 
  = exprs([*pre, stat(putStatic(cls, name, typ, e)), *post]);
                           
list[Instruction] exprs([*Instruction pre, exp(a), GETFIELD(cls, name, typ), *Instruction post]) 
  = exprs([*pre, exp(getField(cls, a, typ, name)), *post]);
    
list[Instruction] exprs([*Instruction pre, exp(a), CHECKCAST(typ), *Instruction post]) 
  = exprs([*pre, exp(checkcast(a, typ)), *post]);  
  
list[Instruction] exprs([*Instruction pre, LDC(typ, constant), *Instruction post]) 
  = exprs([*pre, exp(const(typ, constant)), *post]); 
  
list[Instruction] exprs([*Instruction pre, BIPUSH(int i), *Instruction post]) 
  = exprs([*pre, exp(const(byte(), i)), *post]);          

list[Instruction] exprs([*Instruction pre, exp(a), exp(b), /IF_[IA]CMP<op:EQ|NE|LT|GE|LE>/(str l1), exp(ifBranch), GOTO(str l2), LABEL(l1), exp(elseBranch), LABEL(l2), *Instruction post]) 
  = exprs([*pre, exp(cond(invertedCond(op)(a, b), ifBranch, elseBranch)), LABEL(l2), *post]);

list[Instruction] exprs([*Instruction pre, exp(a), /IF<op:NULL|NONNULL|EQ|NE|LT|GT|LE>/(str l1), exp(ifBranch), GOTO(str l2), LABEL(l1), exp(elseBranch), LABEL(l2), *Instruction post]) 
  = exprs([*pre, exp(cond(invertedCond(op)(a, const(byte(), 0)), ifBranch, elseBranch)), LABEL(l2), *post]);

// short-circuit AND(a,b) 
list[Instruction] exprs(
   [*Instruction pre, 
    exp(a), 
    exp(b), 
    /IF_<op1:[IA]CMP(EQ|NE|LT|GE|LE)>/(str short), 
    exp(c),
    exp(d),
    /IF_<op2:[IA]CMP(EQ|NE|LT|GE|LE)>/(str long),
    LABEL(short),
    *Instruction post
   ]) 
  = exprs([*pre, exp(sand(invertedCond(op1)(a,b), condOp(op2)(c,d))), IFNE(long), LABEL(short), *post]);

// short-circuit OR(a,b) 
list[Instruction] exprs(
   [*Instruction pre, 
    exp(a), 
    exp(b), 
    /IF_<op1:[IA]CMP(EQ|NE|LT|GE|LE)>/(str long), 
    exp(c),
    exp(d),
    /IF_<op2:[IA]CMP(EQ|NE|LT|GE|LE)>/(long),
    *Instruction post
   ]) 
  = exprs([*pre, exp(sor(condOp(op1)(a,b), condOp(op2)(c,d))), IFNE(long), *post]);              
default list[Instruction] exprs(list[Instruction] instr) = instr;


// MAPS

Type typ("I") = integer();
Type typ("F") = float();
Type typ("L") = long();
Type typ("D") = double();
Type typ("S") = short();
Type typ("B") = byte();
Type typ("Z") = boolean();

alias BinOp = Exp (Exp, Exp);

BinOp invertedCond("EQ") = ne;
BinOp invertedCond("NE") = eq;
BinOp invertedCond("LT") = ge;
BinOp invertedCond("GE") = lt;
BinOp invertedCond("GT") = le;
BinOp invertedCond("LE") = gt;
BinOp invertedCond("ICMPEQ") = ne;
BinOp invertedCond("ICMPNE") = eq;
BinOp invertedCond("ICMPLT") = ge;
BinOp invertedCond("ICMPGE") = lt;
BinOp invertedCond("ICMPLE") = gt;
BinOp invertedCond("ACMPEQ") = ne;
BinOp invertedCond("ACMPNE") = eq;

BinOp condOp("EQ") = eq;
BinOp condOp("NE") = ne;
BinOp condOp("LT") = lt;
BinOp condOp("GE") = ge;
BinOp condOp("GT") = gt;
BinOp condOp("LE") = le;
BinOp condOp("ICMPEQ") = eq;
BinOp condOp("ICMPNE") = ne;
BinOp condOp("ICMPLT") = lt;
BinOp condOp("ICMPGE") = ge;
BinOp condOp("ICMPLE") = le;
BinOp condOp("ACMPEQ") = eq;
BinOp condOp("ACMPNE") = ne;

BinOp binOp("ADD") = add;
BinOp binOp("SUB") = sub;
BinOp binOp("MUL") = mul;
BinOp binOp("DIV") = div;
BinOp binOp("REM") = rem;
BinOp binOp("SHL") = shl;
BinOp binOp("SHR") = shr;
BinOp binOp("AND") = and;
BinOp binOp("OR") = or;
BinOp binOp("XOR") = xor;
BinOp binOp("ALOAD") = aload;

alias UnOp = Exp (Exp);

UnOp invertedCond("NULL") = nonnull;
UnOp invertedCond("NONNULL") = null;

Exp nonnull(Exp e) = ne(e, null());
Exp null(Exp e)    = eq(e, null());

// CLEANING UP LEFT-OVER STRUCTURES

@synopsis{removes left-over labels, embedded assembly blocks which only contain statements, and lifts left-over expressions to expression-statements}
list[Stat] clean([*Stat pre, asm([*Instruction preI, LABEL(_), *Instruction postI]), *Stat post]) 
  = clean([*pre, asm([*preI, *postI]), *post]);  

list[Stat] clean([*Stat pre, asm([*Instruction preI, stat(s), *Instruction postI]), *Stat post])
  = clean([*pre, asm(preI), s, asm(postI), *post]);

list[Stat] clean([*Stat pre, asm([*Instruction preI, exp(a), *Instruction postI]), *Stat post])
  = clean([*pre, asm(preI), do(a), asm(postI), *post]); 
  
list[Stat] clean([*Stat pre, asm([]), *Stat post])
  = clean([*pre, *post]);
   
default list[Stat] clean(list[Stat] x) = x; 

// BREAK AND CONTINUE HELPERS

&T breaks(&T l, str breakLabel) = visit(l) {
  case GOTO(breakLabel) => stat(\break())
}; 

&T tryJoins(&T l, str joinLabel) = visit(l) {
  case [*Instruction pre, GOTO(joinLabel), *Instruction post] => [*pre, *post]
}; 

