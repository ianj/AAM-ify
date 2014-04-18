#lang racket/base

#|
This module defines the concrete semantics of reduction for languages written
in the spaces.rkt format.
|#

(require racket/match racket/set racket/dict racket/promise
         racket/list
         racket/trace
         racket/unit
         "spaces.rkt"
         "shared.rkt")
(provide concrete-semantics@)

(define-unit concrete-semantics@
  (import language-parms^)
  (export language-impl^)

  ;; c/match : Language → Pattern DPattern Map[Symbol, DPattern] → Option[Map[Symbol, DPattern]]
;; Concrete match. References' ∀? component does not matter.
;; There is at most one match.
;; If there is a match, the result is the binding environment. Otherwise #f.
(define (c/match pattern data ρ store-spaces)
  (define (inner pattern data ρ)
    (match* (pattern data)
      [((Bvar x Space) d)
       (match (dict-ref ρ x -unmapped)
         [(== -unmapped eq?)
          (cond 
           [Space
            (cond
             [(in-space? L Space d) (dict-set ρ x d)]
             [else
              (log-info (format "Bvar space mismatch ~a ~a~%" Space d))
              #f])]
           [else (dict-set ρ x d)])]
         [other (cond
                 [(equal? other d)
                  ρ]
                 [else
                  (log-info (format "Match failure: non-linear binding mismatch ~a ~a" other d))
                  #f])])]
      [((variant v comps) (variant v* ds))
       (cond
        [(eq? (Variant-name v) (Variant-name v*))
         ;; INVARIANT: Variants with the same name always have the same length.
         (define len (vector-length comps))
         (for/fold ([ρ ρ]) ([comp (in-vector comps)]
                            [d (in-vector ds)])
           (define ρ* (inner comp d ρ))
           #:final (not ρ*)
           ρ*)]
        [else (log-info "Match failure: variant mismatch ~a ~a" pattern data)
              #f])]
      [((? Rvar?) x) (error 'c/match "Unexpected reference in match pattern ~a" x)]

      [((? Address-Structural? a₀) (? Address-Structural? a₁))
       (inner (store-ref store-spaces a₀) (store-ref store-spaces a₁) ρ)]

      [((? dict? m₀) (? dict? m₁))
       (and (= (dict-count m₀) (dict-count m₁))
            (for/and ([(k₀ v₀) (in-dict m₀)])
              (match (dict-ref m₁ k₀ -unmapped)
                [(== -unmapped eq?)
                 ;; Slow path: linearly look for a key "equal" to k with "equal" values.
                 (for/or ([(k₁ v₁) (in-dict m₁)])
                   (and (inner k₀ k₁ ρ)
                        (inner v₀ v₁ ρ)))]
                [v₁ (inner v₀ v₁ ρ)])))]

      ;; this also captures equal Address-Egal values.
      [(atom atom) ρ]
      [(_ _)
       (log-info (format "c/match negative ~a ~a" pattern data))
       #f]))
  (inner pattern data ρ))

;; c/expression-eval : Language Expression Map[Symbol,DPattern] Map[Symbol,Meta-function] → ℘(DPattern)
;; Concrete evaluation of expressions. Returns entire set of possible evaluations
;; due to Choose expressions.
(define (expression-eval e ρ store-spaces)
  (match e
    [(Store-lookup _ kexpr)
     (for/set ([kres (in-set (expression-eval kexpr ρ store-spaces))])
       (match-define (Result/effect kv store-spaces*) kres)
       (Result/effect (store-ref store-spaces kv) store-spaces*))]
    [(Map-lookup _ m kexpr default? dexpr)
     (define ks (expression-eval kexpr ρ store-spaces))
     (define map (hash-ref ρ m (unbound-map-error 'map-ref m)))
     (for/fold ([res ∅]) ([kres (in-set ks)])
       (match-define (Result/effect k store-spaces*) kres)
       (match (hash-ref map k -unmapped)
         [(== -unmapped eq?)
          (if default?
              (set-union res (expression-eval dexpr ρ store-spaces*))
              (error 'map-ref "Key unmapped in map ~a: ~a" m k))]
         [v (set-add res (Result/effect v store-spaces*))]))]
    [(Map-extend _ m kexpr vexpr _)
     (define mv (hash-ref ρ m (unbound-map-error 'map-ext m)))
     (define ks (expression-eval kexpr ρ store-spaces))
     (for/fold ([acc ∅])
         ([kres (in-set ks)])
       (match-define (Result/effect k store-spaces*) kres)
       (for/fold ([acc acc]) ([vres (in-set (expression-eval vexpr ρ store-spaces*))])
       (match-define (Result/effect v store-spaces**) vres)
         (set-add acc (Result/effect (hash-set mv k v) store-spaces**))))]

    [(Meta-function-call _ f arg)
     ;; meta-functions also have non-deterministic choice.
     (mf-eval store-spaces
              (hash-ref Ξ f (λ () (error "Unknown meta-function ~a" f)))
              (pattern-eval arg ρ))]
    [(If _ g t e)
     (for/union ([bres (in-set (expression-eval g ρ store-spaces))])
       (match-define (Result/effect b store-spaces*) bres)
       (if b
           (expression-eval t ρ store-spaces*)
           (expression-eval e ρ store-spaces*)))]
    [(Equal _ l r)
     (for/fold ([acc ∅])
         ([lres (in-set (expression-eval l ρ store-spaces))])
       (match-define (Result/effect lv store-spaces*) lres)
       (for/fold ([acc acc]) ([rres (in-set (expression-eval r ρ store-spaces*))])
         (match-define (Result/effect rv store-spaces**) rres)
         (set-add acc (Result/effect (equal? lv rv) store-spaces**))))]

    ;; Really let with non-linear pattern weirdness.
    [(Let _ bindings bexpr)
     (bindings-eval bindings ρ store-spaces
                    (λ (ρ store-spaces)
                       (expression-eval bexpr ρ store-spaces)))]

    [(Term _ pat) (set (Result/effect (pattern-eval pat ρ) store-spaces))]

    [(In-Dom _ m kexpr)
     (define mv (hash-ref ρ m (unbound-map-error 'map-ext m)))
     (for/set ([kres (in-set (expression-eval kexpr ρ store-spaces))])
       (match-define (Result/effect kv store-spaces*) kres)
       (Result/effect (dict-has-key? mv kv) store-spaces*))]

    [(Set-Union _ exprs)
     (let do-union ([exprs exprs] [cur-set ∅] [store-spaces store-spaces])
       (match exprs
         ['() (set (Result/effect cur-set store-spaces))]
         [(cons expr exprs)
          (for/union ([res (in-set (expression-eval expr ρ store-spaces))])
            (match-define (Result/effect v store-spaces*) res)
            (do-union exprs (set-union cur-set v) store-spaces*))]))]
    [(Set-Add* _ set-expr exprs)
     (for/fold ([acc ∅]) ([sres (in-set (expression-eval set-expr ρ store-spaces))])
       (match-define (Result/effect sv store-spaces*) sres)
       (let do-add ([exprs exprs] [cur-set sv] [store-spaces store-spaces*])
         (match exprs
           ['() (set-union acc (Result/effect cur-set store-spaces))]
           [(cons expr exprs)
            (for/fold ([acc acc]) ([res (in-set (expression-eval expr ρ store-spaces))])
              (match-define (Result/effect v store-spaces*) res)
              (set-union acc
                         (do-add exprs (set-add cur-set v) store-spaces*)))])))]

    [(In-Set _ set-expr expr)
     (for/fold ([acc ∅]) ([sres (in-set (expression-eval set-expr ρ store-spaces))])
       (match-define (Result/effect sv store-spaces*) sres)
       (for/fold ([acc acc]) ([res (in-set (expression-eval expr ρ store-spaces*))])
         (match-define (Result/effect v store-spaces*) res)
         (set-add acc (Result/effect (set-member? sv v) store-spaces*))))]
    [(Empty-set _) (set (Result/effect ∅ store-spaces))]

    ;; We get a set of results from expr. We expect these results to be sets.
    ;; We want to embody any (all) choices from these sets, so we flatten them into
    ;; a set of possible results.
    [(Choose _ expr)
     (for/fold ([acc ∅]) ([res (in-set (expression-eval expr ρ store-spaces))])
       (match-define (Result/effect some-set store-spaces*) res)
       (for/fold ([acc acc]) ([v (in-set some-set)])
         (set-add acc (Result/effect v store-spaces*))))]

    [(or (MAlloc _ space) (QMAlloc _ space _))
     (set (Result/effect (Address-Egal space (gensym)) store-spaces))]
    [(or (SAlloc _ space) (QSAlloc _ space _))
     (set (Result/effect (Address-Structural space (gensym)) store-spaces))]

[bad (error 'expr-eval "Bad expression ~a" bad)]))

(define (bindings-eval bindings ρ store-spaces kont)
  (let proc-bindings ([bindings bindings] [ρ ρ] [store-spaces store-spaces])
    (match bindings
      ['() (kont ρ store-spaces)]
      [(cons (Binding pat cexpr) bindings)
       (for/fold ([acc ∅])
           ([cres (in-set (expression-eval cexpr ρ store-spaces))])
         (match-define (Result/effect cv store-spaces*) cres)
         (match (c/match pat cv ρ store-spaces)
           [#f acc]
           [ρ* (set-union acc (proc-bindings bindings ρ* store-spaces*))]))]
      [(cons (Store-extend kexpr vexpr _) bindings)
       (for/fold ([acc ∅]) ([kres (in-set (expression-eval kexpr ρ store-spaces))])
         (match-define (Result/effect kv store-spaces*) kres)
         (for/fold ([acc acc]) ([vres (in-set (expression-eval vexpr ρ store-spaces*))])
           (match-define (Result/effect vv store-spaces**) vres)
           (set-union acc
                      (proc-bindings bindings ρ (store-set store-spaces kv vv)))))]
      [(cons (When cexpr) bindings)
       (for/fold ([acc ∅]) ([cres (in-set (expression-eval cexpr ρ store-spaces))])
         (match-define (Result/effect cv store-spaces*) cres)
         (if cv
             (set-union acc (proc-bindings bindings ρ store-spaces*))
             acc))])))

;; rule-eval : Rule Map[Symbol,DPattern] DPattern Map[Symbol,Meta-function] → ℘(DPattern)
;; Evaluate a rule on some concrete term and return possible RHSs.
(define (internal-rule-eval store-spaces rule d)
  (match-define (Rule name lhs rhs binding-side-conditions) rule)
  (match (c/match lhs d ρ₀ store-spaces)
    [#f ∅]
    [ρ
     (bindings-eval binding-side-conditions ρ store-spaces
                    (λ (ρ store-spaces)
                       (printf "Eval'd to ~a ~a ~a" rhs ρ (pattern-eval rhs ρ))
                       (set (State (pattern-eval rhs ρ) store-spaces))))]))

(define (rule-eval rule st)
  (match-define (State d store-spaces) st)
  (internal-rule-eval store-spaces rule d))

;; TODO?: Add ability to do safety checks on input/output belonging to a
;;        specified Space.
(define (mf-eval store-spaces mf argd)
  (match-define (Meta-function name rules trust/conc _) mf)
  (if trust/conc
      (trust/conc store-spaces argd)
      ;; Use the first rule that matches. Puns State as Result/effect.
      (for/or ([rule (in-list rules)])
        (define res (internal-rule-eval store-spaces rule argd))
        (and (not (set-empty? res)) res)))))