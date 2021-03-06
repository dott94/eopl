(load-relative "../libs/init.scm")
(load-relative "./base/test.scm")
(load-relative "./base/checked-cases.scm")
(load-relative "./base/store.scm")

;; Extend the checker to handle EXPLICIT-REFS.

;; new stuff
(define-datatype expval expval?
  (num-val
   (value number?))
  (bool-val
   (boolean boolean?))
  (proc-val
   (proc proc?))
  ;;new stuff
  (ref-val
   (ref reference?)))

;;; extractors:
(define expval->num
  (lambda (v)
    (cases expval v
           (num-val (num) num)
           (else (expval-extractor-error 'num v)))))

(define expval->bool
  (lambda (v)
    (cases expval v
           (bool-val (bool) bool)
           (else (expval-extractor-error 'bool v)))))

(define expval->proc
  (lambda (v)
    (cases expval v
           (proc-val (proc) proc)
           (else (expval-extractor-error 'proc v)))))

(define expval-extractor-error
  (lambda (variant value)
    (error 'expval-extractors "Looking for a ~s, found ~s"
           variant value)))

;;;;;;;;;;;;;;;; procedures ;;;;;;;;;;;;;;;;
(define-datatype proc proc?
  (procedure
   (bvar symbol?)
   (body expression?)
   (env environment?)))

(define-datatype environment environment?
  (empty-env)
  (extend-env
   (bvar symbol?)
   (bval expval?)
   (saved-env environment?))
  (extend-env-rec
   (p-name symbol?)
   (b-var symbol?)
   (p-body expression?)
   (saved-env environment?)))


(define init-env
  (lambda ()
    (extend-env
     'i (num-val 1)
     (extend-env
      'v (num-val 5)
      (extend-env
       'x (num-val 10)
       (empty-env))))))

;;;;;;;;;;;;;;;; environment constructors and observers ;;;;;;;;;;;;;;;;
(define apply-env
  (lambda (env search-sym)
    (cases environment env
           (empty-env ()
                      (error 'apply-env "No binding for ~s" search-sym))
           (extend-env (bvar bval saved-env)
                       (if (eqv? search-sym bvar)
                           bval
                           (apply-env saved-env search-sym)))
           (extend-env-rec (p-name b-var p-body saved-env)
                           (if (eqv? search-sym p-name)
                               (proc-val (procedure b-var p-body env))
                               (apply-env saved-env search-sym))))))


(define the-lexical-spec
  '((whitespace (whitespace) skip)
    (comment ("%" (arbno (not #\newline))) skip)
    (identifier
     (letter (arbno (or letter digit "_" "-" "?")))
     symbol)
    (number (digit (arbno digit)) number)
    (number ("-" digit (arbno digit)) number)
    ))

(define the-grammar
  '((program (expression) a-program)

    (expression (number) const-exp)
    (expression
     ("-" "(" expression "," expression ")")
     diff-exp)

    (expression
     ("zero?" "(" expression ")")
     zero?-exp)

    (expression
     ("if" expression "then" expression "else" expression)
     if-exp)

    (expression (identifier) var-exp)

    (expression
     ("let" identifier "=" expression "in" expression)
     let-exp)

    (expression
     ("proc" "(" identifier ":" type ")" expression)
     proc-exp)

    ;; begin new stuff
    (expression
     ("newref" "(" expression ")")
     newref-exp)

    (expression
     ("deref" "(" expression ")")
     deref-exp)

    (expression
     ("setref" "(" expression "," expression ")")
     setref-exp)
    ;; end new stuff

    (expression
     ("(" expression expression ")")
     call-exp)

    (expression
     ("letrec"
      type identifier "(" identifier ":" type ")" "=" expression
      "in" expression)
     letrec-exp)

    (type
     ("int")
     int-type)

    (type
     ("bool")
     bool-type)

    (type
     ("(" type "->" type ")")
     proc-type)

    (type
     ("refto" type)
     refto-type)

    (type
     ("void")
     void-type)

    ))

;;;;;;;;;;;;;;;; sllgen boilerplate ;;;;;;;;;;;;;;;;
(sllgen:make-define-datatypes the-lexical-spec the-grammar)

(define show-the-datatypes
  (lambda () (sllgen:list-define-datatypes the-lexical-spec the-grammar)))

(define scan&parse
  (sllgen:make-string-parser the-lexical-spec the-grammar))

(define just-scan
  (sllgen:make-string-scanner the-lexical-spec the-grammar))

;;;;;;;;;;;;;;;; type-to-external-form ;;;;;;;;;;;;;;;;

;; type-to-external-form : Type -> List
(define type-to-external-form
  (lambda (ty)
    (cases type ty
           (int-type () 'int)
           (bool-type () 'bool)
	   (void-type () 'void)
	   (refto-type (arg-type)
		       (list
			'refto
			(type-to-external-form arg-type)))
           (proc-type (arg-type result-type)
                      (list
                       (type-to-external-form arg-type)
                       '->
                       (type-to-external-form result-type))))))


;; check-equal-type! : Type * Type * Exp -> Unspecified
(define check-equal-type!
  (lambda (ty1 ty2 exp)
    (if (not (equal? ty1 ty2))
        (report-unequal-types ty1 ty2 exp))))

;; report-unequal-types : Type * Type * Exp -> Unspecified
(define report-unequal-types
  (lambda (ty1 ty2 exp)
    (error 'check-equal-type!
           "Types didn't match: ~s != ~a in~%~a"
           (type-to-external-form ty1)
           (type-to-external-form ty2)
           exp)))

  ;;;;;;;;;;;;;;;; The Type Checker ;;;;;;;;;;;;;;;;

;; type-of-program : Program -> Type
(define type-of-program
  (lambda (pgm)
    (cases program pgm
           (a-program (exp1) (type-of exp1 (init-tenv))))))

;; type-of : Exp * Tenv -> Type
(define type-of
  (lambda (exp tenv)
    (cases expression exp
           (const-exp (num) (int-type))

           (var-exp (var) (apply-tenv tenv var))

           (diff-exp (exp1 exp2)
                     (let ((ty1 (type-of exp1 tenv))
                           (ty2 (type-of exp2 tenv)))
                       (check-equal-type! ty1 (int-type) exp1)
                       (check-equal-type! ty2 (int-type) exp2)
                       (int-type)))

           (zero?-exp (exp1)
                      (let ((ty1 (type-of exp1 tenv)))
                        (check-equal-type! ty1 (int-type) exp1)
                        (bool-type)))

           (if-exp (exp1 exp2 exp3)
                   (let ((ty1 (type-of exp1 tenv))
                         (ty2 (type-of exp2 tenv))
                         (ty3 (type-of exp3 tenv)))
                     (check-equal-type! ty1 (bool-type) exp1)
                     (check-equal-type! ty2 ty3 exp)
                     ty2))

           (let-exp (var exp1 body)
                    (let ((exp1-type (type-of exp1 tenv)))
                      (type-of body
                               (extend-tenv var exp1-type tenv))))

           (proc-exp (var var-type body)
                     (let ((result-type
                            (type-of body
                                     (extend-tenv var var-type tenv))))
                       (proc-type var-type result-type)))

           (call-exp (rator rand)
                     (let ((rator-type (type-of rator tenv))
                           (rand-type  (type-of rand tenv)))
                       (cases type rator-type
                              (proc-type (arg-type result-type)
                                         (begin
                                           (check-equal-type! arg-type rand-type rand)
                                           result-type))
                              (else
                               (report-rator-not-a-proc-type rator-type rator)))))


           (letrec-exp (p-result-type p-name b-var b-var-type p-body
                                      letrec-body)
                       (let ((tenv-for-letrec-body
                              (extend-tenv p-name
                                           (proc-type b-var-type p-result-type)
                                           tenv)))
                         (let ((p-body-type
                                (type-of p-body
                                         (extend-tenv b-var b-var-type
                                                      tenv-for-letrec-body))))
                           (check-equal-type!
                            p-body-type p-result-type p-body)
                           (type-of letrec-body tenv-for-letrec-body))))

	   ;; begin new stuff
	   (newref-exp (exp1)
		       (let ((exp-type  (type-of exp1 tenv)))
			 (refto-type exp-type)))

	   (deref-exp (exp1)
		      (let ((exp-type (type-of exp1 tenv)))
			(cases type exp-type
			       (refto-type (arg-type)
					   arg-type)
			       (else
				(report-deref-not-aref exp1)))))

	   (setref-exp (exp1 exp2)
		       (let ((exp-type (type-of exp1 tenv)))
			 (cases type exp-type
				(refto-type (arg-type)
					    (void-type))
				(else
				 (report-setref-not-aref exp1))))))))


(define report-deref-not-aref
  (lambda (arg)
    (error 'type-of-expression
	   "Address of deref is not refto-type: ~% ~s"
	   arg)))

(define report-setref-not-aref
  (lambda (arg)
    (error 'type-of-expression
	   "Address of setref is not a refto-type: ~% ~s"
	   arg)))

(define report-rator-not-a-proc-type
  (lambda (rator-type rator)
    (error 'type-of-expression
           "Rator not a proc type:~%~s~%had rator type ~s"
           rator
           (type-to-external-form rator-type))))


(define-datatype type-environment type-environment?
  (empty-tenv-record)
  (extended-tenv-record
   (sym symbol?)
   (type type?)
   (tenv type-environment?)))

(define empty-tenv empty-tenv-record)
(define extend-tenv extended-tenv-record)

(define apply-tenv
  (lambda (tenv sym)
    (cases type-environment tenv
           (empty-tenv-record ()
                              (error 'apply-tenv "Unbound variable ~s" sym))
           (extended-tenv-record (sym1 val1 old-env)
                                 (if (eqv? sym sym1)
                                     val1
                                     (apply-tenv old-env sym))))))

(define init-tenv
  (lambda ()
    (extend-tenv 'x (int-type)
                 (extend-tenv 'v (int-type)
                              (extend-tenv 'i (int-type)
                                           (empty-tenv))))))


;; value-of-program : Program -> Expval
(define value-of-program
  (lambda (pgm)
    (initialize-store!)
    (cases program pgm
           (a-program (body)
                      (value-of body (init-env))))))


;; value-of : Exp * Env -> ExpVal
(define value-of
  (lambda (exp env)
    (cases expression exp

           (const-exp (num) (num-val num))

	   ;; new stuff
           (var-exp (var) (apply-env env var))

           (diff-exp (exp1 exp2)
                     (let ((val1
                            (expval->num
                             (value-of exp1 env)))
                           (val2
                            (expval->num
                             (value-of exp2 env))))
                       (num-val
                        (- val1 val2))))

           (zero?-exp (exp1)
                      (let ((val1 (expval->num (value-of exp1 env))))
                        (if (zero? val1)
                            (bool-val #t)
                            (bool-val #f))))

           (if-exp (exp0 exp1 exp2)
                   (if (expval->bool (value-of exp0 env))
                       (value-of exp1 env)
                       (value-of exp2 env)))

           (let-exp (var exp1 body)
                    (let ((val (value-of exp1 env)))
                      (value-of body
                                (extend-env var val env))))

           (proc-exp (bvar ty body)
                     (proc-val
                      (procedure bvar body env)))

           (call-exp (rator rand)
                     (let ((proc (expval->proc (value-of rator env)))
                           (arg  (value-of rand env)))
                       (apply-procedure proc arg)))

           (letrec-exp (ty1 p-name b-var ty2 p-body letrec-body)
                       (value-of letrec-body
                                 (extend-env-rec p-name b-var p-body env)))

	   ;; begin new stuff
	   (newref-exp (exp1)
		       (let ((v1 (value-of exp1 env)))
			 (ref-val (newref v1))))

	   (deref-exp (exp1)
		      (let ((v1 (value-of exp1 env)))
			(deref (expval->ref v1))))

	   (setref-exp (exp1 exp2)
		       (let ((ref1 (expval->ref (value-of exp1 env)))
			     (v2  (value-of exp2 env)))
			 (begin
			   (setref! ref1 v2)
			   (num-val 1))))
           )))


;; apply-procedure : Proc * ExpVal -> ExpVal
(define apply-procedure
  (lambda (proc1 arg)
    (cases proc proc1
           (procedure (var body saved-env)
                      (value-of body (extend-env var arg saved-env))))))

(define check
  (lambda (string)
    (type-to-external-form
     (type-of-program (scan&parse string)))))


(define add-test-check!
  (lambda (test)
    (set! tests-for-check (append tests-for-check (list test)))))


(add-test! '(newref-test "let x = newref(0) in letrec int even(d : int) = d in (even 1)" 1))

(check "let x = newref(newref(0)) in deref(x)")
(check "let x = newref(0) in let y = setref(x, 10) in deref(x)")
(run "let x = newref(0) in let y = setref(x, 10) in deref(x)")

(add-test! '(show-allocation-1 "
       let x = newref(22)
       in let f = proc (z : int) let zz = newref(-(z,deref(x))) in deref(zz)
           in -((f 66), (f 55))"
                   11))

(run-all)
(check-all)
