#lang racket/base

(require racket/set (for-syntax racket/base) racket/fixnum)
(provide (all-defined-out))
#|
Allow spaces to be inductively defined or provided with the promise that they are finite
Allow powerset constructor
Allow functions
Allow stores (special)

|#

;; A Language is a (Language Name Symbol Map[Space-name,Either[Space,Component]])
;; Where scope of space names is letrec*
;; All occurrences of the same named Variant are expected to have a total ordering.
;;   That is, some spaces may use a refined notion of a variant, but never a re-defined notion.
(struct Language (name spaces) #:transparent)

;; TODO list for Language sanity checking:
;; - DONE (abstract-language): check for undefined spaces
;; - check for unguarded recursion
;; - check for contradictory Variant declarations
;; - DONE (abstract-language): check that mutually-recursive spaces that declare
;;                             trust-recursion anywhere declare it everywhere

;; A Space is a (Space Symbol List[Variant] Boolean)
;; where the Boolean declares the space as trusted to be bounded even if recursive.

;; A Component is one of
;; - a (Space-reference Name)
;; - an (Address-Space Name)
;; - a (Map Component Component)
;; - a (℘ Component)
;; - (Anything)
;; The Anything variant is special. It stands for a /trusted/ "Any" pattern.

;; A Qualified-Component is a Component with QMaps instead of Maps.
;; TODO?: Add a WeakMap option for automatic GC.

(struct Space-reference (name) #:transparent)
(struct Map (domain range) #:transparent)
(struct QMap (domain domain-precision range) #:transparent)
(struct ℘ (component) #:transparent)
(struct Anything () #:transparent) (define -Anything (Anything))

;; A member of QMap is one of
;; - Dict
;; - (absract-ffun Dict)
;; - (discrete-ffun Dict) [still abstract, but has faster equality tests]
(struct abstract-ffun (dict) #:transparent)
(struct discrete-ffun (dict) #:transparent)

;; TODO?: allow variants or components to have side-conditions
(struct Variant (name Components) #:transparent)
;; Elements of Variant contain a pointer to the type of the variant.
(struct variant (vpointer data) #:transparent)
;; Addresses specify which address space they are in, for store separation purposes.
;; Addresses are classified as either structural or Egal:
;;  - If Must Egal equal, then Must Structural equal. 
;;    Otherwise, dereference both and check equality of product of values;
;;    if all equalities are Must, the equality is must. If all are #f, then the equality is #f. Otherwise May.
;;  - Addresses are Egal equal if syntactically equal (otherwise #f) and
;     if the address cardinality is 1, Must match, else May match.
(struct Address-Structural (space addr) #:transparent)
(struct Address-Egal (space addr) #:transparent)

;; A store is a map from Address to (Space-ref Name).
;; store-spaces is a Map[Address-Space-Name,Store]
;; OPT-OP: precalculate address spaces names and translate to numbers to use vectors instead of hashes.
(struct State (term store-spaces) #:transparent)
;; Create an initial state
(define (mk-State tm) (State tm #hash()))

(struct Abs-State (term σ μ) #:transparent)
(define (mk-Abs-State tm) (Abs-State tm #hash() #hash()))

;; A Precision-Classifier is one of
;; - 'concrete [and thus discrete]
;; - 'discrete-abstraction [considered abstract, but still gets structural equality]
;; - 'abstract [must use slow-path equality checks]

;; A Card is one of
;; - 0
;; - 1
;; - 'ω

;; A Boolean♯ is one of
;; - #t
;; - #f
;; - 'b.⊤

;; A Space is one of
;; - (User-Space List[Either[Variant,Component]] Boolean)
;; - (External-Space (Any → Boolean) (Any [Addr ↦ Card] → Card) Boolean)
;; - (Address-Space)
;; An external space has a predicate that decides membership,
;; a cardinality analysis for values of the space (may be given the abstract count [1] map), and
;; a boolean that is #t iff the cardinality analysis is ever not 1,
;; an optional (Any Any [Addr ↦ Card] → Boolean♯) that quasi-decides equality given count info.
;;  NOTE: if not given, equality falls back on structural equality plus cardinality analysis.
;;
;; A user space may not have duplicate variants.
(struct User-Space (variants trust-recursion?) #:transparent)
(struct Address-Space (space) #:transparent)
(struct External-Space (pred cardinality precision special-equality) #:transparent)

;; A member of an External space is one of
;; - (external external-space Any)
;; - Any [such that the pred of some external space in the language is satisfied]
(struct external (type v) #:transparent)

;; A reduction semantics is a List[Rule]
;; A rule is a (Rule Any Pattern Pattern List[Either[Binding,Side-condition]])
;; A Rule name is used for guiding allocation.

(struct Rule (name lhs rhs binding-side-conditions) #:transparent)

;; A Pattern is one of
;; - a (Bvar Symbol Option[Space-name])
;; - an (Rvar Symbol)
;; - a (variant Variant Immutable-Vector[Pattern]) [morally]
;; - TODO: a (set-with Pattern Pattern) [for structural termination arguments]
;; - TODO: a (map-with QMap Pattern Pattern Pattern) [for structural termination arguments]
;;   XXX: how to handle May-present entries?
;; - an atom
;; Bvar patterns bind on the left if not already mapped.
;; If mapped, an equality check occurs before matching continues.
;; If a Space name is specified, matching ensures the value fits in the space expected.
;; An Rvar refers to a pattern variable in scope.
;; NOTE: If the variable is mapped, an equality check will occur without checking
;;       if the value is in the specified Space (it is assumed to succeed).
;; NOTE: I say morally for immutable, since Racket doesn't have the best support for immutable vectors.
;;       We use standard vectors.
;; NOTE: map-with needs a pointer to the map's type for proper matching.
(struct Bvar (x Space) #:transparent)
(struct Rvar (x) #:transparent)
(define ρ₀ (hash))
(define ∅ (set))
(define ⦃∅⦄ (set ∅))
(define (Avar x) (Bvar x #f))

;; A DPattern (or "data pattern") is either
;; - an atom
;; - a (variant Variant Immutable-Vector[DPattern]) [morally]
;; - a (discrete-ffun Dict)
;; - a (abstract-ffun Dict)
;; - a Dict [trusted to have a concrete domain]
;; - an (Address-Structural _)
;; - an (Address-Egal _)
;; - a Set[DPattern]

(struct Binding (lhs rexpr) #:transparent)
(struct When (expr) #:transparent)
;; Make a syntactic distinction between allocations that expect to have 
;; structural equality (SAlloc) or Egal/Mutable equality (MAlloc)

;; OPT-OP: allow specialized Store-extend and Alloc forms that know statically 
;;         which address space they're using/producing addresses from/to
;; By treating store extensions as bindings, we can control the store flow.
;; We also don't need to make intermediate store names, which is a plus.

;; OPT: classifying expressions with their store interaction allows us to have better
;; allocation strategies when evaluating expressions.
;; If an expression only needs to write to the store, we can output deltas;
;; if only read, the output does not need to allocate for multiple returns;
;; if only alloc, then we only need to change the abstract count, but not the store;
;; and any combinations thereof. It can be advantageous to memoize expressions that do not read the store.
;; A Store-Interation is a combination of
;; - read        (10000b)
;; - write       (01000b)
;; - cardinality (00100b)
;; - alloc       (00010b)
;; - many        (00001b)
;; All encoded as a 5 bit number (fixnum)
(define (reads? n) (fxand n 16))
(define (writes? n) (fxand n 8))
(define (cards? n) (fxand n 4))
(define (allocs? n) (fxand n 2))
(define (many? n) (fxand n 1))

(struct expression (store-interaction) #:transparent)
;; An Expression is one of
;; - (Term Pattern)
;; - Boolean
;; - (Map-lookup Symbol Expression Boolean Expression)
;; - (Map-extend Symbol Expression Expression Boolean)
;; - (Store-lookup Expression)
;; - (If Expression Expression Expression)
;; - (Let List[Binding] Expression
;; - (Equal Expression Expression)
;; - (In-Dom Symbol Expression)
;; - (Empty-set)
;; - (Set-Union List[Expression])
;; - (Set-Add* Expression List[Expression])
;; - (In-Set Expression Expression)
;; and the possibly impure
;; - (Meta-function-call name Pattern)
;; - (Store-extend Expression Expression Boolean)
;; - (SAlloc Symbol)
;; - (MAlloc Symbol)
;; - (QSAlloc Symbol _)
;; - (QMAlloc Symbol _)

(struct Store-extend (key-expr val-expr trust-strong?) #:transparent)

;; Notes: The boolean in Map-extend is whether the map should remain a strong update through abstraction.
;; This only matters for maps that have addresses in their domains.

(struct Term expression (pat) #:transparent)

(struct Map-lookup expression (mvar key-expr default? def-expr) #:transparent)
(struct Map-extend expression (mvar key-expr val-expr trust-strong?) #:transparent)
(struct Store-lookup expression (key-expr) #:transparent)

(struct Meta-function-call expression (name arg-pat) #:transparent)

(struct If expression (g t e) #:transparent)
(struct Equal expression (l r) #:transparent)
(struct Let expression (bindings body-expr) #:transparent)
(struct In-Dom expression (mvar key-expr) #:transparent)

(struct Set-Union expression (exprs) #:transparent)
(struct Empty-set expression () #:transparent)
(struct Set-Add* expression (set-expr exprs) #:transparent)
(struct In-Set expression (set-expr expr) #:transparent)

(struct Unsafe-store-space-ref expression () #:transparent)
(struct Unsafe-store-ref expression (space) #:transparent)

;; If expecting a set, make an arbitrary choice.
(struct Choose expression (expr) #:transparent)

(struct SAlloc expression (space) #:transparent)
(struct MAlloc expression (space) #:transparent)
;; Qualified forms.
(struct QSAlloc expression (space hint) #:transparent)
(struct QMAlloc expression (space hint) #:transparent)

;; When evaluating top-level-forms, we can allocate addresses and change the store.
;; When expressions have these side-effects, we wrap the contents in the following.
(define-syntax Result/effect (make-rename-transformer #'State))

;; We attach a quality of a result to qualify if it follows from cumulatively
;; strong or weak side-conditions in Let or top-level forms.
;; Implicit side-effects include weak store/map lookups
;; Non-determinism resulting from abstraction is different since evaluation is
;; considered "successful," even if approximate.
(struct Abs-Result/effect (quality term store-spaces μ) #:transparent)

;; the definition of a meta-function is like a reduction semantics,
;; but treated like a functional relation.
;; Any use of addresses can lead to non-determinism and several results, but
;; each recursive position of a variant pattern can be labeled with '∀ or '∃ to control
;; in which way evaluation of the meta-function goes.
;; For example, if we have side-conditions checking each element of a list for a property,
;; I can label the rest position as '∀ to ensure every abstract list denotation has the property.
;; I can also use '∃ to make sure at least one list has the property.
;; Further, we allow custom implementations of a meta-function if the specifier wishes for more control.

;; A Meta-function is a
;; (Meta-function Symbol List[Rule] Option[DPattern → DPattern] Option[DPattern → ℘(DPattern)])
;; TODO: termination back-door?
(struct Meta-function (name rules trusted-implementation/conc trusted-implementation/abs) #:transparent)

;; A unique value to distinguish lookup failures.
(struct Unmapped ()) (define -unmapped (Unmapped))

;; A Component-Address is one of
;; - '℘
;; - 'domain
;; - 'range

;; A Variant-Address is a Pair[Variant-field,List[Component-Address]]
(struct Variant-field (name index) #:transparent)
(struct Space-component (name) #:transparent)

;; An Allocation-Address is a List[(∪ Variant-field Component-Address)]