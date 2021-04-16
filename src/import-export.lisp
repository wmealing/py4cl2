;; Functions and macros for importing and exporting symbols to python

;;;; Things we need to achieve - in case someone wants to attempt refactorisation
;;; For defpyfun:
;;;   - For convenience, we need to be able to show the function's arguments and
;;;   default values in Slime.
;;;   - For customizability, we ought to be able to load some "config" file
;;;   containing name, signature, documentation, call method for some functions.
;;;   This latter hasn't been attempted yet.

(in-package :py4cl2)

(defun pymethod-list (python-object &key (as-vector nil))
  (raw-pyexec "import inspect")
  (let ((method-vector (pyeval "[name for name, ele in inspect.getmembers("
                               python-object ", callable)]")))
    (if as-vector method-vector (coerce method-vector 'list))))

(defun pyslot-list (python-object &key (as-vector nil))
  (raw-pyexec "import inspect")
  (raw-pyexec "
def _py4cl_non_callable(ele):
  import inspect
  return not(inspect.isroutine(ele))")
  (let ((slot-vector
          (pyeval "[name for name, ele in inspect.getmembers("
                  python-object
                  ", _py4cl_non_callable)]")))
    (if as-vector slot-vector (coerce slot-vector 'list))))

(defun builtin-p (pymodule-name)
  "Some builtin functions like 'sum' do not take keyword args."
  (or (null pymodule-name)
      (string= "" pymodule-name)))

(defun fun-symbol (pyfun-name pyfullname lisp-package &optional (ensure-unique t))
  (if ensure-unique
      (let ((callable-type (cond ((pyeval "inspect.isfunction(" pyfullname ")") 'function)
                                 ((pyeval "inspect.isclass(" pyfullname ")") 'class)
                                 (t t)))
            (lisp-fun-name (lispify-name pyfun-name)))
        (intern (case callable-type
                  (class (concatenate 'string lisp-fun-name "/CLASS"))
                  (function (if (upper-case-p (char pyfun-name 0))
                                (concatenate 'string lisp-fun-name "/1")
                                lisp-fun-name))
                  (t (get-unique-symbol lisp-fun-name lisp-package)))
                lisp-package))
      ;; later, specialize further if needed
      (intern (lispify-name pyfun-name) lisp-package)))

;; In essence, this macro should give the full power of the
;;   "from modulename import function as func"
;; to the user.

;; "from keras.layers import Input" creates only "Input" and not
;; "keras.layers.Input" in python;
;; However, this leaves open the chance of a name conflict
;; - what if two python modules have the same name?
;; defpymodule takes care of this, along with keeping minimal work
;; in defpyfun

(defmacro defvar-doc (name doc)
  `(progn
     (defvar ,name)
     (setf (documentation ',name 'variable) ,doc)))

(defvar *called-from-defpymodule* nil
  "Internal variable used for coordinating between DEFPYMODULE and DEFPYFUN.")
(defvar *defpymodule-silent-p* nil
  "DEFPYMODULE avoids printing progress if this is T.")
(defvar-doc *function-reload-string*
  "String pyexec-ed at the start of a DEFPYFUN when SAFETY is T.")
(defvar-doc *lisp-package-supplied-p*
  "Internal variable used by PYMODULE-IMPORT-STRING to determine the import string.")
(defvar-doc *defpymodule-cache*
  "If non-NIL, DEFPYMODULE produces the expansion during macroexpansion time.
  Use intended for DEFPYSUBMODULES.")

(defmacro defpyfun (fun-name
                    &optional pymodule-name
                    &key
                      (as fun-name)
                      (cache t)
                      (lisp-fun-name (lispify-name as))
                      (lisp-package *package*)
                      (safety t))
  "
Defines a function which calls python
Example
  (py4cl:pyexec \"import math\")
  (py4cl:defpyfun \"math.sqrt\")
  (math.sqrt 42) -> 6.4807405

Arguments:

  FUN-NAME: name of the function in python, before import
  PYMODULE-NAME: name of the module containing FUN-NAME

  AS: name of the function in python, after import
  CACHE: if non-NIL, constructs the function body at macroexpansion time
  LISP-FUN-NAME: name of the lisp symbol to which the function is bound*
  LISP-PACKAGE: package (not its name) in which LISP-FUN-NAME will be interned
  SAFETY: if T, adds an additional line in the function asking to import the
    package or function, so that the function works even after PYSTOP is called.
    However, this increases the overhead of stream communication, and therefore,
    can reduce speed.
  "
  (if cache
      (defpyfun* fun-name pymodule-name
        as lisp-fun-name lisp-package safety)
      `(eval-when (:compile-toplevel :load-toplevel :execute)
         (eval (defpyfun* ',fun-name ',pymodule-name
                 ',as ',lisp-fun-name ',lisp-package ',safety)))))

(defun defpyfun* (fun-name pymodule-name as lisp-fun-name lisp-package safety)
  (check-type fun-name string)
  (check-type lisp-fun-name string)
  (check-type lisp-package package)
  (check-type pymodule-name (or null string))
  (python-start-if-not-alive)
  (raw-pyexec "import inspect")
  ;; (format t "*called-from-defpymodule* ~D in ~D~%"
  ;;         *called-from-defpymodule*
  ;;         fun-name)
  (unless (or *called-from-defpymodule*
              (builtin-p pymodule-name))
    (raw-pyexec (function-reload-string :pymodule-name pymodule-name
                                        :fun-name fun-name
                                        :as as)))
  (let* ((fullname (if *called-from-defpymodule*
                       (concatenate 'string pymodule-name "." fun-name)
                       (or as fun-name)))
         (fun-doc (pyeval fullname ".__doc__"))
         (fun-symbol (intern lisp-fun-name lisp-package)))
    (destructuring-bind (parameter-list pass-list)
        (get-arg-list fullname (find-package lisp-package))
      (let ((common-code
              `(progn
                 (defun ,fun-symbol (,@parameter-list)
                   ,(or fun-doc "Python function")
                   ,(first pass-list)
                   ,(when safety
                      (if (builtin-p pymodule-name)
                          `(python-start-if-not-alive)
                          (if *called-from-defpymodule*
                              `(raw-pyexec ,*function-reload-string*)
                              `(raw-pyexec ,(function-reload-string :pymodule-name
                                                                    pymodule-name
                                                                    :fun-name fun-name
                                                                    :as as)))))
                   ,(second pass-list)))))
        #-ecl
        `(restart-case
             ,common-code
           (continue-ignoring-errors nil))
        #+ecl
        common-code))))

(defvar *is-submodule* nil
  "Used for coordinating import statements from defpymodule while calling recursively")

;;; packages in python are collection of modules; module is a single python file
;;; In fact, all packages are modules; but all modules are not packages.
(defun defpysubmodules (pymodule-name lisp-package continue-ignoring-errors)
  (let ((submodules
          (pyeval "tuple((modname, ispkg) for importer, modname, ispkg in "
                  "pkgutil.iter_modules("
                  pymodule-name
                  ".__path__))")))
    (when (and (stringp submodules)
               (string= "None" submodules))
      (setq submodules nil))
    (iter (for (submodule has-submodules) in submodules)
      (for submodule-fullname = (concatenate 'string
                                             pymodule-name "." submodule))
      (when (and (char/= #\_ (aref submodule 0)) ; avoid private modules / packages
                 ;; pkgutil is of type module
                 ;; import matplotlib does not import matplotlib.pyplot
                 ;; https://stackoverflow.com/questions/14812342/matplotlib-has-no-attribute-pyplot
                 ;; We maintain these semantics.
                 ;; The below form errors in the case of submodules and
                 ;; therefore returns NIL.
                 (ignore-errors (pyeval "type(" submodule-fullname
                                        ") == type(pkgutil)")))
        (let ((*is-submodule* t))
          (collect
              (macroexpand-1
               `(defpymodule ,submodule-fullname
                    ,has-submodules
                    :cache ,*defpymodule-cache*
                    :lisp-package ,(concatenate 'string lisp-package "."
                                                (lispify-name submodule))
                    :continue-ignoring-errors ,continue-ignoring-errors))))))))

(declaim (ftype (function (string string)) pymodule-import-string))
(defun pymodule-import-string (pymodule-name lisp-package)
  (let ((package-in-python (pythonize (intern lisp-package))))
    (values
     (cond (*is-submodule* "")
           (*lisp-package-supplied-p*
            (concatenate 'string "import " pymodule-name
                         " as " package-in-python))
           (t (concatenate 'string "import " pymodule-name)))
     package-in-python)))

(defun function-reload-string (&key pymodule-name lisp-package fun-name as)
  (if *called-from-defpymodule*
      (pymodule-import-string pymodule-name lisp-package)
      (concatenate 'string "from " pymodule-name " import " fun-name " as " as)))

(defun ensure-package (package-name &rest args)
  (or (find-package package-name) (apply #'make-package package-name args)))

;;; One we need is the name of the package inside python
;;; And the other is the name of the package inside lisp
;;; The relation between the two being that the lisp name should
;;; pythonize to the python name.

;;; A discussion pertaining to the side-effects here is at
;;;   https://github.com/digikar99/py4cl2/pull/13
;;; A prime reason for doing the work during macroexpansion is so
;;; that the further loading of the fasls generated from files containing
;;; the defpymodule forms is (much) quicker.

(defmacro defpymodule (pymodule-name
                       &optional (import-submodules nil)
                       &key (cache t)
                         (continue-ignoring-errors t)
                         (lisp-package (lispify-name pymodule-name) lisp-package-supplied-p)
                         (reload t)
                         (recompile-on-change nil)
                         (safety t)
                         (silent *defpymodule-silent-p*))
  "
Import a python module (and its submodules) as a lisp-package(s).
Example:
  (py4cl:defpymodule \"math\" :lisp-package \"M\")
  (m:sqrt 4)   ; => 2.0

Arguments:

  PYMODULE-NAME: name of the module in python, before importing
  IMPORT-SUBMODULES: leave nil for purposes of speed, if you won't use the
    submodules

  CACHE: if non-NIL, produces the DEFPACKAGE and DEFUN forms at macroexpansion time
    to speed-up future reloads of the system
  LISP-PACKAGE: lisp package, in which to intern (and export) the callables
  RECOMPILE-ON-CHANGE: the name of the ASDF system to recompile if the python version of
    PYMODULE-NAME changes; this only has effect if CACHE is non-NIL
  RELOAD: redefine the LISP-PACKAGE if T
  SAFETY: value of safety to pass to defpyfun; see defpyfun
  SILENT: prints \"status\" lines when NIL"
  (let ((*defpymodule-cache* cache))
    (if cache                
        (handler-bind ((pyerror (lambda (e)
                                  (if continue-ignoring-errors
                                      (invoke-restart 'continue-ignoring-errors)
                                      e))))
          (restart-case
              (multiple-value-bind (package-exists-p-form ensure-package-form defpackage-form)
                  (defpymodule* pymodule-name
                    import-submodules
                    lisp-package
                    lisp-package-supplied-p
                    reload
                    safety
                    continue-ignoring-errors
                    silent)
                `(progn
                   ,package-exists-p-form
                   ,(when recompile-on-change
                      `(unless (string= ,(pyeval pymodule-name ".__version__")
                                        (pyeval ,pymodule-name ".__version__"))
                         (asdf:compile-system ,recompile-on-change :force t :verbose nil)))
                   (eval-when (:compile-toplevel :load-toplevel :execute)
                     ,ensure-package-form)
                   ,defpackage-form))
            (continue-ignoring-errors nil)))      
        `(eval-when (:compile-toplevel :load-toplevel :execute)
           (eval (cons 'progn
                       (multiple-value-list
                        (defpymodule* ',pymodule-name
                          ',import-submodules
                          ',lisp-package
                          ',lisp-package-supplied-p
                          ',reload
                          ',safety
                          ',continue-ignoring-errors
                          ',silent))))))))  ; (defpymodule "torch" t) is one test case


(defun defpymodule* (pymodule-name import-submodules
                     lisp-package lisp-package-supplied-p
                     reload safety continue-ignoring-errors silent)
  "
Returns multiple values:
- a DEFVAR form to capture the existence of package before ensuring it
- an ENSURE-PACKAGE form
- the actual form that defines the package and functions
  "
  (check-type pymodule-name string) ; is there a way to (declaim (macrotype ...?
  (check-type lisp-package string)

  ;; This form is necessary, until
  ;; (i)  slime displays case sensitive names
  ;; (ii) case sensitive lisp becomes mainstream
  ;; Because, until then, for "convenience", multiple python names
  ;;   python_name PythonName Python_name pythonName
  ;; will map to the same lisp name
  (let ((package (find-package lisp-package))) ;; reload
    (if package
        (if reload
            (delete-package package)
            (return-from defpymodule* "Package already exists."))))

  (python-start-if-not-alive)           ; Ensure python is running

  (raw-pyexec "import inspect")
  (raw-pyexec "import pkgutil")

  ;; fn-names  All callables whose names don't start with "_"
  (let ((*lisp-package-supplied-p* lisp-package-supplied-p)
        (*defpymodule-silent-p* silent))
    (multiple-value-bind (package-import-string package-in-python)
        (pymodule-import-string pymodule-name lisp-package)
      (raw-pyexec package-import-string)
      (when (and reload (not silent))
        (format t "~&Defining ~A for accessing python package ~A..~%"
                lisp-package
                package-in-python))
      (let* ((fun-names (pyeval "tuple(name for name, fn in inspect.getmembers("
                                package-in-python
                                ", callable) if name[0] != '_')"))
             ;; Get the package name by passing through reader,
             ;; rather than using STRING-UPCASE
             ;; so that the result reflects changes to the readtable
             ;; Note that the package doesn't use CL to avoid shadowing.
             (exporting-package (ensure-package lisp-package :use '()))
             (fun-symbols (mapcar (lambda (pyfun-name)
                                    (fun-symbol pyfun-name
                                                (concatenate 'string
                                                             package-in-python
                                                             "."
                                                             pyfun-name)
                                                lisp-package))
                                  (if (and (stringp fun-names)
                                           (or (string= "()" fun-names)
                                               (string= "None" fun-names)))
                                      (setq fun-names ())
                                      fun-names)))
             (package-exists-p (gensym "PACKAGE-EXISTS-P"))
             (fun-symbol-names (mapcar #'symbol-name fun-symbols)))
        (values `(defvar ,package-exists-p (find-package ,lisp-package))
                ;; We need the package to even read the next form!
                ;; But we can only know if or not the package exists beforehand
                ;; before creating it! After creating it, it definitely exists!
                `(uiop:ensure-package ,lisp-package
                                      :use ()
                                      :export ',fun-symbol-names)
                ;; `(ensure-package  :use '())
                `(,@(if reload
                        `(progn)
                        `(unless ,package-exists-p))
                  (defpackage ,lisp-package
                    (:use)
                    (:export ,@fun-symbol-names))
                  ,@(if import-submodules
                        (defpysubmodules package-in-python
                          lisp-package
                          continue-ignoring-errors))
                  ,@(iter (for fun-name in fun-names)
                      (for fun-symbol in fun-symbols)
                      (collect
                          (let* ((*called-from-defpymodule* t)
                                 (*function-reload-string*
                                   (function-reload-string :pymodule-name pymodule-name
                                                           :lisp-package lisp-package
                                                           :fun-name fun-name)))
                            (defpyfun* fun-name
                              package-in-python
                              fun-name
                              (format nil "~A" fun-symbol)
                              exporting-package
                              safety))))
                  t))))))

(defmacro defpyfuns (&rest args)
  "Each ARG is supposed to be a 2-3 element list of
 (pyfun-name pymodule-name) or (pyfun-name pymodule-name lisp-fun-name).
In addition, when ARG is a 2-element list, then, the first element can be
a list of python function names. "
  `(progn
     ,@(iter outer
         (for arg-list in args)
         (ecase (length arg-list)
           (2 (etypecase (first arg-list)
                (list (iter
                        (for pyfun-name in (first arg-list))
                        (in outer (collect `(defpyfun ,pyfun-name
                                                ,(second arg-list))))))
                (string (collect `(defpyfun ,@arg-list)))))
           (3 (collect `(defpyfun ,(first arg-list) ,(second arg-list)
                          :lisp-fun-name ,(third arg-list))))))))

(defun export-function (function python-name)
  "Makes a lisp FUNCTION available in python process as PYTHON-NAME"
  (raw-pyexec (concatenate 'string
                           python-name
                           "=_py4cl_LispCallbackObject("
                           (write-to-string
                            (object-handle function))
                           ")")))
