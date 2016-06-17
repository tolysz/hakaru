# Teach Maple (through depends and eval) about our new binding forms.
# forall bind from 1st arg to 2nd arg.
# Ints,Sums,ints,sums bind from 2nd arg to 1st arg, and also from each element
#   of the 4th arg to the other elements on the left and to the 3rd arg.

`depends/forall` := proc(bvar, pred, x, $)
  depends(pred, x minus convert(bvar, 'set'))
end proc:

`depends/Ints` := proc(body, bvar, rng, loops, x, $)
  local xx, i;
  if depends(body, x minus {bvar}) then return true end if;
  xx := x; # don't remove bvar from xx!
  for i from nops(loops) to 1 by -1 do
    if depends(op([i,2],loops), xx) then return true end if;
    xx := xx minus {op([i,1],loops)};
  end do;
  depends(rng, xx)
end proc:
`depends/Sums` := `depends/Ints`:
`depends/ints` := `depends/Ints`:
`depends/sums` := `depends/Ints`:

`eval/forall` := proc(e, eqs, $)
  local bvar, pred;
  bvar, pred := op(e);
  eval(op(0,e), eqs)(BindingTools:-generic_evalat(bvar, pred, eqs))
end proc:

`eval/Ints` := proc(e, eqs, $)
  local body, bvar, rng, loops, n, i;
  body, bvar, rng, loops := op(e);
  bvar, body := BindingTools:-generic_evalat(bvar, body, eqs);
  eval(op(0,e), eqs)(body, bvar,
                     BindingTools:-generic_evalatstar(rng, loops, eqs))
end proc:
`eval/Sums` := `eval/Ints`:
`eval/ints` := `eval/Ints`:
`eval/sums` := `eval/Ints`:

`eval/Int` := proc(e, eqs, $)
  local body, bound, bvar;
  body, bound := op(1..2, e);
  if bound :: name then
    bound, body := BindingTools:-generic_evalat(bound, body, eqs);
  elif bound :: `=` then
    bvar := lhs(bound);
    bvar, body := BindingTools:-generic_evalat(bvar, body, eqs);
    bound := bvar = eval(rhs(bound), eqs);
  else
    body, bound := BindingTools:-generic_evalatstar(body, bound, eqs);
  end if;
  eval(op(0,e), eqs)(body, bound, op(eval([op(3..-1,e)], eqs)))
end proc:
`eval/Sum` := `eval/Int`:
`eval/int` := `eval/Int`:
`eval/sum` := `eval/Int`:

#############################################################################

Loop := module ()
  option package;
  local intssums, wrap, Binder, Stmt, t_binder, t_stmt, t_exp;
  export
     # These first few are smart constructors (for themselves):
         ints, sums,
     # while these are "proper functions"
         genLoop, unproducts, unproduct;
  # these names are not assigned (and should not be).  But they are
  # used as global names, so document that here.
  global Ints, Sums;
  uses Hakaru, KB;

  t_binder := 'Binder(identical(product, Product, sum, Sum), t_kb)';
  t_stmt   := 'Stmt(anything, list, list)';
  t_exp    := '{Stmt(identical(exp), [], []),
                Stmt(identical(`^`), [anything], [])}';

  ints := proc() intssums('ints', 'int', _passed) end proc;
  sums := proc() intssums('sums', 'sum', _passed) end proc;

  intssums := proc(makes::name, make::name,
                   e::anything, x::name, rr::range, ll::list(name=range),
                   kb::t_kb:=empty, $)
    local r, l, kb1, w0, pp;
    r, l, kb1 := genLoop(rr, ll, kb, 'Integrand'(x,e));
    w0, pp := unproducts(e, x, l, kb1);
    if depends(w0, x) then 'makes'(e, x, rr, ll)
    else w0 * foldl(product, make(pp,x=r), op(l)) end if
  end proc;

  genLoop := proc(e, loops::list(name=range), kb::t_kb)
    local kb1, rng, ind, do_subst, i;
    kb1 := kb;
    rng := table();
    ind := table();
    do_subst := e -> foldl(((e,eq) -> eval(e, op([lhs(eq),1],loops)=rhs(eq))),
                           e, entries(ind, 'pairs'));
    for i from nops(loops) to 1 by -1 do
      rng[i] := do_subst(op([i,2],loops));
      ind[i], kb1 := genType(op([i,1],loops), HInt(closed_bounds(rng[i])),
                               kb1, _rest);
    end do;
    do_subst(e), zip(`=`, [entries(ind, 'nolist')],
                          [entries(rng, 'nolist')]), kb1
  end proc;

  unproducts := proc(w, x::name, loops::list(name=range), kb::t_kb, $)
    local w0, pp, j, w1, w2, xx;
    w0 := 1;
    pp := w;
    for j from nops(loops) to 1 by -1 do
      w1, pp := op(unproduct(pp, x, op(j,loops), [], `*`, kb, kb));
      # separate out each of the products, as they might have different
      # variable dependencies, which can be exploited by other routines
      w2 := convert(w1, 'list', '`*`');
      w2 := map[2](foldl, product, w2, op(j+1..-1, loops));
      w0 := w0 * `*`(op(w2));
      # w0 := w0 * foldl(product, w1, op(j+1..-1, loops));
    end do;
    w0, pp
  end proc;

  # Find [w1,pp] so that
  #   wrap(heap,w,mode,kb1,kb0)
  #   = w1*product(eval(pp,var=idx(var,lhs(loop))),loop)
  # making w1 depend on var as little as possible.
  # The flag "mode" should be `+` if "heap" contains an entry of the form
  # t_exp, or `*` otherwise.
  unproduct := proc(w, var::name, loop::(name=range),
                    heap::list, mode::identical(`*`,`+`),
                    kb1::t_kb, kb0::t_kb, $)
    local ind, res, dummy, kb, kbThen, i, w1, pp, s, r, x;
    if not depends(w, var) then
      return [wrap(heap, w, mode, kb1, kb0), 1]
    end if;
    ind := map2(op, 2, indets(w, Hakaru:-idx(identical(var), anything)));
    if nops(ind) = 1 then
      ind := op(ind);
      # Make sure ind contains no bound variables before lifting it!
      # So, check that "extract using indets" and "rename using eval" commute.
      s := indets(ind, 'name');
      s := map(proc(x,$) local y; `if`(depends(ind,x), x=y, NULL) end proc, s);
      if indets(eval(w, s), Hakaru:-idx(identical(var), anything))
         = {Hakaru:-idx(var, eval(ind, s))} then
        kb  := assert(lhs(loop)=ind, kb1);
        res := subs(Hakaru:-idx(var,ind) = Hakaru:-idx(var,lhs(loop)), w);
        res := wrap(heap, res, mode, kb, kb0);
        res := subs(Hakaru:-idx(var,lhs(loop))=dummy, res);
        if not depends(res, var) then
          return [1, subs(dummy=var, res)]
        end if
      end if
    end if;
    if w :: mode then
      res := map(unproduct, `if`(mode=`*`, list_of_mul(w,kb1), [op(w)]),
                 var, loop, heap, mode, kb1, kb0);
      return [`*`(op(map2(op,1,res))), `*`(op(map2(op,2,res)))]
    end if;
    if w :: 'specfunc(piecewise)' then
      kb := kb1;
      for i from 1 to nops(w) do
        if i :: even then
          kbThen := assert(    op(i-1,w) , kb);
          kb     := assert(Not(op(i-1,w)), kb);
          w1[i], pp[i] := op(unproduct(op(i,w),var,loop,heap,mode,kbThen,kb0))
        elif i = nops(w) then
          w1[i], pp[i] := op(unproduct(op(i,w),var,loop,heap,mode,kb    ,kb0))
        end if
      end do;
      return [`*`(entries(w1,'nolist')), `*`(entries(pp,'nolist'))]
    end if;
    if mode = `*` then
      if w :: (anything^freeof(var)) then
        return unproduct(op(1,w), var, loop,
                         [op(heap), Stmt(`^`, [], [op(2,w)])], `*`, kb1, kb0)
      elif w :: exp(anything) then
        return unproduct(op(1,w), var, loop,
                         [op(heap), Stmt(exp, [], [])], `+`, kb1, kb0)
      elif w :: (freeof(var)^anything) then
        return unproduct(op(2,w), var, loop,
                         [op(heap), Stmt(`^`, [op(1,w)], [])], `+`, kb1, kb0)
      end if
    end if;
    if mode = `+` and w :: `*` then
      s, r := selectremove(depends, w, var);
      if s :: `*` then
        # Nonlinear %1 (time to reread kiselyov-lifted?)
      else
        return unproduct(s, var, loop,
                         [op(heap), Stmt(`*`, [], [r])], `+`, kb1, kb0)
      end if
    end if;
    if w :: And(specfunc(`if`(mode = `*`, {product, Product}, {sum, Sum})),
                anyfunc(anything, name=range(freeof(var)))) then
      x, kb := genType(op([2,1],w),
                       HInt(Bound(`>=`,op([2,2,1],w)),
                            Bound(`<=`,op([2,2,2],w))),
                       kb1,
                       w, var, loop, heap);
      return unproduct(eval(op(1,w), op([2,1],w)=x), var, loop,
                       [op(heap), Binder(op(0,w), kb1)], mode, kb, kb0)
    end if;
    return [wrap(heap, w, mode, kb1, kb0), 1]
  end proc;

  wrap := proc(heap::list, e1, mode1::identical(`*`,`+`),
               kb1::t_kb, kb0::t_kb, $)
    local e, kb, mode, i, entry, rest, var, new_var, new_rng, make, 
       dom_spec, w, arrrgs, cond;
    e    := e1;
    kb   := kb1;
    mode := mode1;
    for i from nops(heap) to 1 by -1 do
      entry := op(i,heap);
      if entry :: t_binder then
        if not (op(1,entry) in `if`(mode=`+`, {sum,Sum},
                                              {product,Product})) then
          print("Warning: heap mode inconsistency", heap, mode1)
        end if;
        rest := kb_subtract(kb, op(2,entry));
        new_rng, rest := selectremove(type, rest,
          {[identical(genType), name, specfunc(HInt)],
           [identical(genLet), name, anything]});
        if not (new_rng :: [list]) then
          error "kb_subtract should return exactly one gen*"
        end if;
        new_rng := op(new_rng);
        var     := op(2,new_rng);
        if op(1,new_rng) = genType then
          make    := op(1,entry);
          new_rng := range_of_HInt(op(3,new_rng));
        else # op(1,new_rng) = genLet
          make    := eval;
          new_rng := op(3,new_rng);
        end if;
        dom_spec, rest := selectremove(depends,
          map(proc(a::[identical(assert),anything],$) op(2,a) end proc, rest),
          var);
        (e, w) := selectremove(depends, convert(e, 'list', `*`), var);
        e := simplify_assuming(`*`(op(e)), kb);
        w := simplify_assuming(`*`(op(w)), kb);
        if nops(dom_spec) > 0 then
          cond := op(dom_spec);
          # if e = mode(), don't bother with the piecewise
          if not (e = mode()) then
            # if e itself is a piecewise of the right shape, merge
            if e :: 'specfunc(piecewise)' and nops(e)=3 and op(3,e) = mode() then
              cond := op(1,e), cond;
              e := op(2,e);
            end if;
            e := piecewise(And(cond), e, mode())
          end if;
        end if;
        if mode=`+` then
          e  := w * make(e, var=new_rng);
        elif mode=`*` then
          if make = genLet then
            e := w * make(e, var = new_rng);
          elif nops(dom_spec) > 0 then
            new_var := gensym(var);
            e := w ^ sum(eval(piecewise(And(op(dom_spec)), 1, 0), var = new_var), new_var = new_rng) *
                 make(e, var = new_rng);
          else
            e := w ^ sum(1, var = new_rng) * make(e, var = new_rng);
          end if;
        end if;
        kb := foldr(assert, op(2,entry), op(rest));
      elif entry :: t_stmt then
        # We evaluate arrrgs first, in case op(1,stmt) is an operation (such as
        # piecewise) that looks ahead at how many arguments it is passed before
        # they are evaluated.
        arrrgs := op(op(2,entry)), e, op(op(3,entry));
        e      := op(1,entry)(arrrgs);
        if entry :: t_exp then
          if mode <> `+` then
            print("Warning: heap mode inconsistency?", heap, mode1)
          end if;
          mode := `*`;
        end if
      else error "Malformed heap entry %1", entry end if
    end do;
    if mode <> `*` then
      print("Warning: heap mode inconsistency??", heap, mode1)
    end if;
    rest := kb_subtract(kb, kb0);
    rest := map(proc(a::[identical(assert),anything],$) op(2,a) end proc, rest);
    if nops(rest) > 0 and not (e = mode ()) then
      e := piecewise(And(op(rest)),e,mode())
    end if;
    e
  end proc;

end module; # NewSLO
