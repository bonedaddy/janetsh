(import shlib :prefix "")

# This file is the main implementation of janetsh.
# The best reference I have found so far for new people is here:
# https://www.gnu.org/software/libc/manual/html_node/Implementing-a-Shell.html

(var initialized false)

(var on-tty nil)

# Stores the last saved tmodes of the shell.
# Set and restored when running jobs in the foreground.
(var shell-tmodes nil)

# All current jobs under control of the shell.
(var jobs nil)

# Mapping of pid to process tables.
(var pid2proc nil)

# Extremely unsafe table. Don't touch this unless
# you know what you are doing.
#
# It holds the pid cleanup table for signals and an atexit
# handler and must only ever be updated after signals are disabled.
#
# It is even a janet implementation detail that READING
# a table doesn't modify it's structure, as such it is
# better to not even read this table without cleanup
# signals disabled...
(var unsafe-child-cleanup-array nil)

# Reentrancy counter for shell signals...
(var disable-cleanup-signals-count 0)

(defn- disable-cleanup-signals []
  (when (= 1 (++ disable-cleanup-signals-count))
    (mask-cleanup-signals SIG_BLOCK)))

(defn- enable-cleanup-signals []
  (when (= 0 (-- disable-cleanup-signals-count))
    (mask-cleanup-signals SIG_UNBLOCK))
  (when (< disable-cleanup-signals-count 0)
    (error "BUG: unbalanced signal enable/disable pair.")))

(defn- force-enable-cleanup-signals []
  (set disable-cleanup-signals-count 0)
  (mask-cleanup-signals SIG_UNBLOCK))

(defn- rebuild-unsafe-child-cleanup-array
  []
  (var new-unsafe-child-cleanup-array @[])
  (disable-cleanup-signals)
  (each j jobs
    (when (j :cleanup)
      (each p (j :procs)
        (array/push new-unsafe-child-cleanup-array (p :pid)))))
  (set unsafe-child-cleanup-array new-unsafe-child-cleanup-array)
  (register-unsafe-child-cleanup-array unsafe-child-cleanup-array)
  (enable-cleanup-signals))

(defn init
  [&opt is-subshell]
  (when initialized
    (break))

  (when (not= disable-cleanup-signals-count 0)
    (error "bug"))
  (set jobs @[])
  (set pid2proc @{})
  
  (rebuild-unsafe-child-cleanup-array)
  (register-atexit-cleanup)
  
  (set on-tty
    (and (isatty STDIN_FILENO)
         (= (tcgetpgrp STDIN_FILENO) (getpgrp))))
  (if is-subshell
    (set-noninteractive-signal-handlers)
    (set-interactive-signal-handlers))
  
  (set initialized true)
  nil)

(defn deinit
  []
  (when (not initialized)
    (break))
  (disable-cleanup-signals)
  (set jobs @[])
  (set pid2proc @{})
  (rebuild-unsafe-child-cleanup-array)
  (unregister-atexit-cleanup)
  (reset-signal-handlers)
  (force-enable-cleanup-signals)
  (set initialized false))

(defn- new-job []
  # Don't manpulate job tables directly, instead
  # use provided job management functions.
  @{
    :procs @[]    # A list of processes in the pipeline.
    :tmodes nil   # Saved terminal modes of the job if it was stopped.
    :pgid nil     # Job process group id.
    :cleanup true # Cleanup on job on exit.
   })

(defn- new-proc []
  @{
    :args @[]         # A list of arguments used to start the proc. 
    :env @{}          # New environment variables to set in proc.
    :redirs @[]       # A list of 3 tuples. [fd|path ">"|"<"|">>" fd|path] 
    :pid nil          # PID of process after it has been started.
    :termsig nil      # Signal used to terminate job.
    :exit-code nil    # Exit code of the process when it has exited, or 127 on signal exit.
    :stopped false    # If the process has been stopped (Ctrl-Z).
    :stopsig nil      # Signal that stopped the process.
   })

(defn update-proc-status
  [p status]
  (when (WIFSTOPPED status)
    (put p :stopped true)
    (put p :stopsig (WSTOPSIG status)))
  (when (WIFCONTINUED status)
    (put p :stopped false))
  (when (WIFEXITED status)
    (put p :exit-code (WEXITSTATUS status)))
  (when (WIFSIGNALED status)
    (put p :exit-code 129)
    (put p :termsig (WTERMSIG status))))

(defn update-pid-status
  "Given a pid and status, update the corresponding process
   in the global job/process tables with the new status."
  [pid status]
  (when-let [p (pid2proc pid)]
    (update-proc-status p status)))

(defn job-stopped?
  [j]
  (reduce (fn [s p] (and s (p :stopped))) true (j :procs)))

(defn job-exit-code
  "Return the exit code of the first failed process
   in the job. Ignores processes that failed due to SIGPIPE
   unless they are the last process in the pipeline.
   Returns nil if any job has not exited."
  [j]
  (def last-proc (last (j :procs)))
  (reduce
    (fn [code p]
      (and
        code
        (p :exit-code)
        (if (and (zero? code)
                 (or (not= (p :termsig) SIGPIPE) (= p last-proc)))
          (p :exit-code)
          code)))
    0 (j :procs)))

(defn job-complete?
  "Returns true when all processes in the job have exited."
  [j]
  (number? (job-exit-code j)))

(defn signal-job 
  [j sig]
  (try
    (kill (- (j :pgid)) sig)
  ([e] 
    (when (not= ESRCH (dyn :errno))
      (error e)))))

(defn- continue-job
  [j]
  (each p (j :procs)
    (put p :stopped false))
  (signal-job j SIGCONT))

(defn- mark-missing-job-as-complete
  [j]
  (each p (j :procs)
    (when (not (p :exit-code))
      # Last ditch effort to wait for PID (not pgid).
      # of missing process so we don't leak processes.
      # One example where this may happen is if the child
      # dies before it has a chance to call setpgid.
      (try 
        (waitpid (p :pid) (bor WUNTRACED WNOHANG))
        ([e] nil))
      (put p :exit-code 129))))

(defn wait-for-job
  [j]
  (try
    (while (not (or (job-stopped? j) (job-complete? j)))
      (let [[pid status] (waitpid (- (j :pgid)) (bor WUNTRACED WCONTINUED))]
        (update-pid-status pid status)))
  ([err]
    (if (= ECHILD (dyn :errno))
      (mark-missing-job-as-complete j)
      (error err))))
  j)

(defn update-job-status
  "Poll and update the status and exit codes of the job without blocking."
  [j]
  (try
    (while true
      (let [[pid status] (waitpid (- (j :pgid)) (bor WUNTRACED WNOHANG WCONTINUED))]
        (when (= pid 0) (break))
        (update-pid-status pid status)))
    ([err]
      (if (= ECHILD (dyn :errno))
        (mark-missing-job-as-complete j)
        (error err)))))

(defn update-all-jobs-status
  "Poll all active jobs and update their status information without blocking."
  []
  (each j jobs
    (when (not (job-complete? j))
      (update-job-status j)))
  jobs)

(defn terminate-job
  [j]
  (when (not (job-complete? j))
    (signal-job j SIGTERM)
    (wait-for-job j))
  j)

(defn job-from-pgid [pgid]
  (find (fn [j] (= (j :pgid)) pgid) jobs))

(defn terminate-all-jobs
  []
  (each j jobs (terminate-job j)))

(defn prune-complete-jobs
  "Poll active jobs without blocking and then remove completed jobs
   from the jobs table."
  []
  (update-all-jobs-status)
  (set jobs (filter (complement job-complete?) jobs))
  (set pid2proc @{})
  
  (rebuild-unsafe-child-cleanup-array)

  (each j jobs
    (each p (j :procs)
      (put pid2proc (p :pid) p)))
  jobs)

(defn disown-job
  [j]
  (put j :cleanup false)
  (rebuild-unsafe-child-cleanup-array))

(defn fg-job
  "Shift job into the foreground and give it control of the terminal."
  [j]
  (when (not on-tty)
    (error "cannot move job to foreground when not on a tty."))
  (set shell-tmodes (tcgetattr STDIN_FILENO))
  (when (j :tmodes)
    (tcsetattr STDIN_FILENO TCSADRAIN (j :tmodes)))
  (update-job-status j)
  (when (not (job-complete? j))
    (tcsetpgrp STDIN_FILENO (j :pgid))
    (when (job-stopped? j)
      (continue-job j))
    (wait-for-job j))
  (tcsetpgrp STDIN_FILENO (getpgrp))
  (put j :tmodes (tcgetattr STDIN_FILENO))
  (tcsetattr STDIN_FILENO TCSADRAIN shell-tmodes)
  (job-exit-code j))

(defn bg-job
  "Resume a stopped job in the background."
  [j]
  (when (job-stopped? j)
    (continue-job j)))

(defn- do-setenv
  [env]
  (each ev (pairs env)
    (os/setenv (ev 0) (ev 1))))

(defn- close-redir-sources
  [redirs]
  
  (defn is-std-fileno
    [fd]
    (find (partial = fd) [STDIN_FILENO STDOUT_FILENO STDERR_FILENO]))

  (each redir redirs
    (let [src (redir 2)]
      (match (type src)
      :number
        (unless (is-std-fileno src)
          (close src))
      :core/file
        (unless (is-std-fileno (file/fileno src))
          (file/close src))))))

(defn- do-redirs
  [redirs]
  (each r redirs
    (var sinkfd (get r 0))
    (var src  (get r 2))
    (var srcfd nil)
    
    (when (or (tuple? src) (array? src))
      (when (not= (length src) 1)
        (error "redirect target tuple has more than one member."))
      (set src (first src)))

    (match (type src)
      :string
        (set srcfd (match (r 1)
          ">"  (open src (bor O_WRONLY O_CREAT O_TRUNC)  (bor S_IWUSR S_IRUSR S_IRGRP))
          ">>" (open src (bor O_WRONLY O_CREAT O_APPEND) (bor S_IWUSR S_IRUSR S_IRGRP))
          "<"  (open src (bor O_RDONLY) 0)
          (error "unhandled redirect")))
      :number
        (set srcfd src)
      :core/file
        (set srcfd (file/fileno src))
      (error "unsupported redirect target type"))
    
    (dup2 srcfd sinkfd)))

(defn pipes
  "Creates a pair of connected pipes as files and
   return them as a tuple, the first file is read only,
   the second file is write only. These files can be
   used as redirection targets."
  []
  (let [[a b] (pipe)
        fa (file/fdopen a :r)
        fb (file/fdopen b :w)]
    (if (and fa fb)
      [fa fb]
      (do
        (if fa
          (file/close fa)
          (close a))
        (if fb
          (file/close fb)
          (close b))
        (error "unable to create pipes")))))

(defn- exec-proc
  [proc]

  # The child doesn't want our signal handlers
  # or any other stuff like job tables and cleanup.
  (deinit)

  (do-setenv (proc :env))
  (do-redirs (proc :redirs))

  (defn- run-subshell-proc [f]
    # This is a subshell inside a job.
    # Clear jobs, they aren't the subshell's jobs.
    # The subshells should be able to run jobs
    # of it's own if it wants to.
    (init true)
    
    (var rc 0)
    (try
      (f (tuple/slice (proc :args) 1))
      ([e]
        (set rc 1)
        (file/write stderr (string "error: " e "\n"))))
    
    (file/flush stdout)
    (file/flush stderr)
    (os/exit rc))

  (var entry-point (first (proc :args)))
  (cond
    (function? entry-point)
      (run-subshell-proc entry-point)
    (table? entry-point)
      (run-subshell-proc (fn [eargs] (:post-fork entry-point eargs)))
    (exec ;(map string (proc :args)))))
    
(defn launch-job
  [j in-foreground]
  (when (not initialized)
    (error "uninitialized janetsh runtime."))
  (try
    (do
      # Disable cleanup signals
      # so our cleanup code doesn't
      # miss any pid's and doesn't
      # interrupt us setting up the pgid.
      (disable-cleanup-signals)
      
      # Flush output files before we fork.
      (file/flush stdout)
      (file/flush stderr)
      
      (def procs (j :procs))
      (var pipes nil)
      (var infd  STDIN_FILENO)
      (var outfd STDOUT_FILENO)
      (var errfd STDERR_FILENO)

      (for i 0 (length procs)
        (let 
          [proc (get procs i)
           has-next (not= i (dec (length procs)))]
          
          (if has-next
            (do
              (set pipes (pipe))
              (set outfd (pipes 1)))
            (do
              (set pipes nil)
              (set outfd STDOUT_FILENO)))

          (when (table? (first (proc :args)))
            (:pre-fork (first (proc :args)) proc))

          # As mentioned here[1], we must set the right pgid
          # in both the parent and the child to avoid a race
          # condition when we start waiting on the process group before
          # it is actually created.
          # 
          # [1] https://www.gnu.org/software/libc/manual/html_node/Launching-Jobs.html#Launching-Jobs 
          (defn 
            post-fork [pid]
            (when (not (j :pgid))
              (put j :pgid pid))
            (try
              (do
                (setpgid pid (j :pgid))
                (when (and on-tty in-foreground)
                  (tcsetpgrp STDIN_FILENO (j :pgid))))
            ([e]
              # These errors all seem to be caused by the child's premature
              # death racing with the necessary setup in the shell and child.
              # The worse case of ignoring this error seem to
              # be that this child was really killed before it called setpgid.
              # This should make a missing job which we will detect later.
              # It is not really a race anymore because the child is dead.
              (when (not (find (partial = (dyn :errno)) [EACCES EPERM ESRCH]))
                (error e))))
            (put proc :pid pid)
            (put pid2proc pid proc))

          (var pid (fork))
          
          (when (zero? pid)
            (try # Prevent a child from ever returning after an error.
              (do
                (set pid (getpid))
                
                # TODO XXX.
                # We want to discard any buffered input after we fork.
                # There is currently no way to do this. (fpurge stdin)
                (post-fork pid)

                (when pipes
                  (close (pipes 0)))

                # We are in the child, no harm in updating
                # the proc table in place.
                (array/insert (proc :redirs) 0
                    @[STDIN_FILENO  "<"  infd]
                    @[STDOUT_FILENO ">" outfd]
                    @[STDERR_FILENO ">"  errfd])
                (exec-proc proc)
                (error "unreachable"))
            ([e] (do (file/write stderr (string e "\n")) (os/exit 1)))))

          (close-redir-sources (proc :redirs))

          (post-fork pid)

          (when (not= infd STDIN_FILENO)
            (close infd))
          (when (not= outfd STDOUT_FILENO)
            (close outfd))
          (when pipes
            (set infd (pipes 0)))))

      (array/push jobs j)
      # Since we inserted a new job
      # we should prune the old jobs
      # which also configures the cleanup array.
      (prune-complete-jobs)
      (enable-cleanup-signals)
      
      (if in-foreground
        (if on-tty
          (fg-job j)
          (wait-for-job j))
        (bg-job j))
      j)
    ([e] # This error is unrecoverable to ensure things like running out of FD's
         # don't leave the terminal in an undefined state.
      (file/write stderr (string "unrecoverable internal error: " e)) 
      (file/flush stderr)
      (os/exit 1))))

(defn- job-output-rc [j]
  (let [[fa fb] (pipes)]
    (array/push ((last (j :procs)) :redirs) @[STDOUT_FILENO ">" fb])
    (launch-job j false)
    (let [output (file/read fa :all)]
      (file/close fa)
      (wait-for-job j)
      [(string output) (job-exit-code j)])))

(defn- job-output [j]
  (let [[output rc] (job-output-rc j)]
    (if (= 0 rc)
      output
      (error (string "job failed! (status=" rc ")")))))

(defn- get-home
  []
  (or (os/getenv "HOME") ""))

(defn- expand-getenv 
  [s]
  (or 
    (match s
      "PWD" (os/cwd)
      (os/getenv s))
    ""))

(defn- tildhome
  [s] 
  (string (get-home) "/"))

(def- expand-parser (peg/compile
  ~{
    :env-esc (replace (<- "$$") "$")
    :env-seg (* "$" (replace
                      (+ (* "{" (<- (some (* (not "}") 1)) ) "}" )
                         (<- (some (+ "_" (range "az") (range "AZ"))))) ,expand-getenv))
    :lit-seg (<- (some (* (not "$") 1)))
    :main (* (? (replace (<- "~/") ,tildhome)) (any (choice :env-esc :env-seg :lit-seg)))
  }))

(defn expand
  "Perform shell expansion on the provided string.
  Will expand a leading tild, environment variables
  in the form '$VAR '${VAR}' and path globs such
  as '*.txt'. Returns an array with the expansion."
  [s]
  (var s s)
  (when (= s "~") (set s (get-home)))
  (glob (string ;(peg/match expand-parser s))))

(defn- norm-redir
  [& r]
  (var @[a b c] r)
  (when (and (= "" a) (= "<" b))
    (set a 0))
  (when (and (= "" a) (or (= ">" b) (= ">>" b)))
    (set a 1))
  (when (= c "")
    (set c nil))
  (when (string? c)
    (set c (tuple first (tuple expand c))))
  @[a b c])

(def- redir-parser (peg/compile
  ~{
    :fd (replace (<- (some (range "09"))) ,scan-number)
    :redir
      (* (+ :fd (<- "")) (<- (+ ">>" ">" "<")) (+ (* "&" :fd ) (<- (any 1))))
    :main (replace :redir ,norm-redir)
  }))

(defn- parse-redir
  [r]
  (let [match (peg/match redir-parser r)]
    (when match (first match))))

(def- env-var-parser (peg/compile
  ~{
    :main (sequence (capture (some (sequence (not "=") 1))) "=" (capture (any 1)))
  }))

(defn- parse-env-var
  [s]
  (peg/match env-var-parser s))

(defn- arg-symbol?
  [f]
  (match (type f)
    :symbol true
    :keyword true
    false))

(defn- form-to-arg
  "Convert a form to a form that is
   shell expanded at runtime."
  [f]
  (match (type f)
    :tuple
      (if (= (tuple/type f) :brackets)
        f
        (if (and # Somewhat ugly special case. Check for the quasiquote so we can use ~/ nicely.
              (= (first f) 'quasiquote)
              (= (length f) 2)
              (= (type (f 1)) :symbol))
          (tuple expand (string "~" (f 1)))
          f))
    :keyword
      (tuple expand (string f))
    :symbol
      (tuple expand (string f))
    :number
      (string f)
    :boolean
      (string f)
    :string
      f
    :array
      f
    :nil
      "nil"
    (error (string "unsupported shell argument type: " (type f)))))

# Table of builtin name to constructor
# function for builtin objects.
#
# A builtin has two methods:
# :pre-fork [self {:args args}]
# :post-fork [self {:args args}]
(var *builtins* nil) # intialized after builtin definitions.

(defn- replace-builtins
  [args]
  (when-let [bi (*builtins* (first args))]
    (put args 0 (bi)))
  args)

# Stores defined aliases in the form @{"ls" ["ls" "-la"]}
# Can be changed directly, or with the helper macro.
(var *aliases* @{})

(defmacro alias
  [& cmds]
  "Install an alias while following normal process argument expansion.
   Example:  (sh/alias ls ls -la)
   "
  ~(if-let [expanded (map string (flatten ,(map form-to-arg cmds)))
            name (first expanded)
            rest (tuple/slice expanded 1)
            _ (not (empty? rest))]
      (put ',*aliases* name rest)
      (error "alias expects at least two expanded arguments")))

(defn unalias [name]
  (put *aliases* name nil))

(defn- replace-aliases
  [args]
  (if-let [alias (*aliases* (first args))]
    (array/concat (array ;alias) (array/slice args 1))
    args))

(defn parse-job
  [& forms]
  (var state :env)
  (var job (new-job))
  (var proc (new-proc))
  (var fg true)
  (var pending-redir nil)
  (var pending-env-assign nil)
  
  (defn handle-proc-form
    [f]
    (cond
      (= '| f) (do 
                 (array/push (job :procs) proc)
                 (set state :env)
                 (set proc (new-proc)))
      (= '& f) (do (set fg false) (set state :done))
      
      (let [redir (parse-redir (string f))]
        (if (and (arg-symbol? f) redir)
          (if (redir 2)
            (array/push (proc :redirs) redir)
            (do (set pending-redir redir) (set state :redir)))
          (array/push (proc :args) (form-to-arg f))))))
  
  (each f forms
    (match state
      :env
        (if-let [ev (and (symbol? f) (parse-env-var (string f)))
                 [e v] ev]
          (if (empty? v)
            (do (set pending-env-assign e)
                (set state :env2))
            (put (proc :env) e v))
          (do
            (set state :proc)
            (handle-proc-form f)))
      :env2
         (do
          (put (proc :env) pending-env-assign 
            (if (arg-symbol? f)
              (string f)
              (tuple string f)))
          (set state :env))
      :proc 
        (handle-proc-form f)
      :redir
        (do
          (put pending-redir 2 (form-to-arg f))
          (array/push (proc :redirs) pending-redir)
          (set state :proc))
      :done (error "unexpected input after command end")
      (error "bad parser state")))
  (when (= state :redir)
    (error "redirection missing target"))
  (when (< 0 (length (proc :args)))
      (array/push (job :procs) proc))
  (when (empty? (job :procs))
    (error "empty shell job"))
  
  (each proc (job :procs)
    (put proc :args
      (tuple replace-builtins
        (tuple replace-aliases (tuple flatten (proc :args))))))
  [job fg])

(defn do-lines
  "Return a function that calls f on each line of stdin.\n\n
   Primarily useful for subshells."
  [f]
  (fn [args]
    (while true
      (if-let [ln (file/read stdin :line)]
        (f ln)
        (break)))))

(defn out-lines
  "Return a function that calls f on each line of stdin.\n\n
   writing the result to stdout if it is not nil.\n\n 
   
   Example: \n\n

   (sh/$ echo \"a\\nb\\nc\" | (out-lines string/ascii-upper))"
  [f]
  (do-lines 
    (fn [ln]
      (when-let [xln (f ln)]
        (file/write stdout xln)))))

(defmacro $
  "Execute a shell job (pipeline) in the foreground or background with 
   a set of optional redirections for each process.\n\n
  
   If the job is a foreground job, this macro waits till the 
   job either stops, or exits. If the job exits with an error
   status the job raises an error.\n\n

   If the job is a background job, this macro returns a the job table entry 
   that can be used to manage the job.\n\n

   Jobs take the exit code of the first failed process in the job with one
   exception, processes that terminate due to SIGPIPE do not count towards the 
   job exit code.\n\n

   Symbols inside the $ are treated more or less like a traditional shell with 
   some exceptions:\n\n
   
   - Janet keywords can be used to escape janet symbol rules. \n\n
   - A Janet call inside a job are treated as janet code janet mode.
     Escaped janet code can return either a function in the place of a process name, strings, 
     or nested arrays of strings which are flattened on invocation. \n\n
   - The quasiquote operator ~ is handled specially for convenience in simple cases, but 
    for complex cases string quoting may be needed. \n\n
   
   Examples:\n\n

   (sh/$ ls *.txt | cat )\n
   (sh/$ ls @[\"/\" [\"/usr\"]])\n
   (sh/$ ls (os/cwd))
   (sh/$ ls (os/cwd) >/dev/null :2>'1 )\n
   (sh/$ (fn [args] (pp args)) hello world | cat )\n
   (sh/$ \"ls\" (sh/expand \"*.txt\"))\n
   (sh/$ sleep (+ 1 5) &)\n"

  [& forms]
  (let [[j fg] (parse-job ;forms)]
  ~(do
    (let [j ,j]
      (,launch-job j ,fg)
      (if ,fg
        (let [rc (,job-exit-code j)]
          (when (not= 0 rc)
            (error rc)))
        j)))))

(defn- fn-$?
  [forms]
    (let [[j fg] (parse-job ;forms)]
    ~(do
      (let [j ,j]
        (,launch-job j ,fg)
        (if ,fg
          (,job-exit-code j)
          j)))))

(defmacro $?
  "Execute a shell job in the foreground or background with 
   a set of optional redirections for each process returning the job exit code.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (fn-$? forms))

(defmacro $??
  "Execute a shell job in the foreground or background with 
   a set of optional redirections for each process returning true or false
   depending on whether the job was a success.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (let [rc-forms (fn-$? forms)]
    ~(= 0 ,rc-forms)))

(defn- fn-$$
  [forms]
    (let [[j fg] (parse-job ;forms)]
      (when (not fg)
        (error "$$ does not support background jobs"))
      ~(,job-output ,j)))

(defmacro $$
  "Execute a shell job in the foreground with 
   a set of optional redirections for each process returning the job stdout as a string.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (fn-$$ forms))

(defmacro $$_
  "Execute a shell job in the foreground with 
   a set of optional redirections for each process returning
   the job stdout as a trimmed string.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (let [out-forms (fn-$$ forms)]
    ~(,string/trimr ,out-forms)))

(defn- fn-$$?
  [forms]
    (let [[j fg] (parse-job ;forms)]
      (when (not fg)
        (error "$$? does not support background jobs"))
      ~(,job-output-rc ,j)))

(defmacro $$?
  "Execute a shell job in the foreground with 
   a set of optional redirections for each process returning
   a tuple of stdout and the job exit code.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (fn-$$? forms))

(defmacro $$_?
  "Execute a shell job in the foreground with 
   a set of optional redirections for each process returning
   a tuple of the trimmed stdout and the job exit code.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  ~(let [[out rc] ,(fn-$$? forms)]
    [(,string/trimr out) rc]))

(defmacro $-pipe
  "Execute a shell job in the background returning
   a file that can be used to read the job stdout.\n\n

   See the $ documenation for examples and more detailed information about the
   accepted syntax."
  [& forms]
  (let [[j fg] (parse-job ;forms)]
  ~(do
    (let [j ,j
          [fa fb] (,pipes)]
      (array/push ((last (j :procs)) :redirs) @[,STDOUT_FILENO ">" fb])
      (,launch-job j false)
      fa))))


# Shell builtins

(defn- make-cd-builtin
  []
  @{
    :pre-fork
      (fn builtin-cd
        [self {:args args}]
        (try
          (let [args (tuple/slice args 1)]
            (os/cd ;
              (if (empty? args)
                 [(or (os/getenv "HOME") (error "cd: HOME not set"))]
                 args)))
          ([e] (put self :error e))))
    :post-fork
      (fn builtin-cd
        [self args]
        (when (self :error)
          (error (self :error))))
    :error nil
  })

(defn- make-exec-builtin
  []
  @{
    :pre-fork
      (fn builtin-exec
        [self proc]
        (try
          (let [args (tuple/slice (proc :args) 1)]
            (if (empty? args)
              (do
                (do-setenv (proc :env))
                (do-redirs (proc :redirs)))
              (do
                (atexit-cleanup)
                (array/remove (proc :args) 0)
                (exec-proc proc))))
          ([e]
            (file/write stderr (string "exec failed: " e "\n"))
            (os/exit 1))))
    :post-fork
      (fn builtin-exec
        [self args]
        nil)
  })

# Dir stack used by 'dirs', 'pushd' and 'popd'
(var *dirs* @[])

(defn- make-dirs-builtin
  []
  @{
    :pre-fork
      (fn builtin-dirs
        [self {:args args}]
        nil)
    :post-fork
      (fn builtin-dirs
        [self args]
        (each d (reverse *dirs*)
          (pp d)))
    :error nil
  })

(defn- make-pushd-builtin
  []
  @{
    :pre-fork
      (fn builtin-pushd
        [self {:args args}]
        (try
          (let [args (tuple/slice args 1)]
            (when (> (length args) 1)
              (error "expected: pushd [DIR]"))
            (def owd (os/cwd))
            (os/cd (or (first args) (os/getenv "HOME") (error "pushd: HOME not set")))
            (array/push *dirs* owd))
          ([e] (put self :error e))))
    :post-fork
      (fn builtin-pushd
        [self args]
        (when (self :error)
          (error (self :error))))
    :error nil
  })

(defn- make-popd-builtin
  []
  @{
    :pre-fork
      (fn builtin-popd [self {:args args}]
        (try
          (let [args (tuple/slice args 1)]
            (cond
              (and (= (first args) "-n") (= (length args) 1))
                (array/pop *dirs*)
              (empty? args)
                (os/cd (array/pop *dirs*))
              (error "expected: popd [-n]" )))
        ([e] put self :error e)))
    :post-fork
      (fn builtin-popd
        [self args]
        (when (self :error)
          (error (self :error))))
    :error nil
  })

(defn- make-clear-builtin
  []
  @{
    :pre-fork
      (fn builtin-clear [self {:args args}] nil)
    :post-fork
      (fn builtin-clear
        [self args]
        (file/write stdout "\x1b[H\x1b[2J"))
  })

(defn- make-exit-builtin
  []
  @{
    :pre-fork
      (fn builtin-exit
        [self {:args args}]
        (try
          (let [args (tuple/slice args 1)]
            (when (empty? args)
              (os/exit 0))
            (if-let [code (and (= (length args) 1) (scan-number (first args)))]
              (os/exit code)
              (error "expected: exit NUM")))
        ([e] (put self :error e))))
    :post-fork
      (fn builtin-exit
        [self args]
        (error (self :error)))
    :error nil
  })

(defn- make-alias-builtin
  []
  @{
    :pre-fork
      (fn builtin-alias [self {:args args}]
        (try
          (let [args (tuple/slice args 1)]
            (var fst (first args))
            (cond
               (= fst "-h") nil
               (empty? args) nil
               (and (= (length args) 1) (= (*aliases* fst) nil))
                 (error (string "alias: " fst " not found"))
               (= (length args) 1) nil

               # put specific alias
               (when-let [alias fst
                          cmd (tuple/slice args 1)]
                 (put *aliases* alias cmd))))
          ([e] (put self :error e))))
    :post-fork
      (fn builtin-alias [self args]
        (var fst (first args))
        (cond
          (self :error) (error (self :error))
          (= fst "-h")
            (file/write stdout "alias name [commands]\n")
          (empty? args)
            (each [alias cmd] (pairs *aliases*)
              (file/write stdout
                (string "alias " alias " " (string/join cmd " ") "\n")))
          (= (length args) 1)
            (when-let [alias fst
                       cmd (*aliases* alias)]
              (file/write stdout
                (string "alias " alias " " (string/join cmd " ") "\n")))))
    :error nil
  })

(defn- make-unalias-builtin
  []
  (def help "unalias [-a] name [name ...]")
  @{
    :pre-fork
      (fn builtin-unalias [self {:args args}]
        (try
          (let [args (tuple/slice args 1)]
            (var fst (first args))
            (case fst
              nil nil
              "-h" nil
              "-a"
                # unalias all
                (each alias (keys *aliases*)
                  (put *aliases* alias nil))

              (each alias args
                (if (*aliases* alias)
                  (put *aliases* alias nil)
                  (put self :error (string "unalias: " fst " not found"))))))
        ([e] (put self :error e))))
    :post-fork
      (fn builtin-unalias [self args]
        (when (self :error)
          (error (self :error)))
        (case (first args)
          nil
            (print help)
          "-h"
            (print help)))
    :error nil
  })

(defn- make-export-builtin
  []
  @{
    :pre-fork
      (fn builtin-export [self {:args args}]
        (try
          (let [args (tuple/slice args 1)]
            (var state :env1)
            (var pending-e nil)
            (each arg args
              (match state
                :env1
                  (if-let [ev (parse-env-var arg)
                           [e v] ev]
                    (if (empty? v)
                      (do
                        (set pending-e e)
                        (set state :env2))
                      (os/setenv e v))
                    (error "expected env assignment."))
                :env2
                  (do
                    (os/setenv pending-e arg)
                    (set state :env1))))
            (when (not= state :env1)
              (error "export: bad env assignment")))
        ([e] (put self :error e))))
    :post-fork
      (fn builtin-export
        [self args]
        (when (self :error)
          (error (self :error))))
    :error nil
  })

(set *builtins* @{
  "exec" make-exec-builtin
  "clear" make-clear-builtin
  "cd" make-cd-builtin
  "alias" make-alias-builtin
  "unalias" make-unalias-builtin
  "exit" make-exit-builtin
  "dirs" make-dirs-builtin
  "pushd" make-pushd-builtin
  "popd" make-popd-builtin
  "export" make-export-builtin
})

# Default completions

(defn get-completions
  "Determine the appropriate completions for a given line from
   a particular start and end position.\n\n

   This is the default value for *get-completions*."
  [line start end env]

  (defn- expand-completion
    [comp]
    (->> (expand comp)
         (map (fn [f]
                (if-let [stat (os/stat f)]
                  (if (and (= (stat :mode) :directory)
                           (not= (last f) ("/" 0)))
                    (string f "/")
                    f)
                  f)))))

  (defn- scan-for-completions
    [prefix &opt modes permissions]
    (defn desired-file?
      [p]
      (when-let [stat (os/stat p)]
        (default modes @[:file :directory])
        (and (find (fn [m] (= m (stat :mode))) modes)
             (if permissions
               (string/find permissions (stat :permissions))
               true))))
    (var single (expand-completion prefix))
    (when (= (length single) 1)
      (->> (expand-completion (string prefix "*"))
           (filter desired-file?)
           (map (fn [exp] (string/slice (string/slice exp (length (first single)))))))))

  (defn- completion-wants
    [line start to-expand]
    (var i (dec start))
    (var wants (if (string/find "/" to-expand) :local-bin :bin))
    (while (>= i 0)
      (cond
        (= (line i) ("|" 0))
        (break)

        (= (line i) ("(" 0))
        (do (set wants :function)
            (break))

        (not= (line i) (" " 0))
        (do (set wants :local-file)
            (break))

        (-- i)))
    wants)

  (var completions @[])
  (var to-expand (string (string/slice line start end)))
  (match (completion-wants line start to-expand)
    :local-file
     (each completion (scan-for-completions to-expand)
       (array/push completions (string to-expand completion)))
     :local-bin
     (each completion (scan-for-completions to-expand @[:file :directory] "x")
       (array/push completions (string to-expand completion)))
     :bin
     (do
       (array/concat completions
                     (->> (keys *builtins*)
                          (filter (fn [bi] (string/has-prefix? to-expand bi)))))
       (each path-ent (string/split ":" (os/getenv "PATH"))
         (each completion (scan-for-completions (string path-ent "/" to-expand)
                                                @[:file] "x")
           (array/push completions (string to-expand completion)))))
     :function
     (set completions
          (->> (all-bindings env)
               (map string)
               (filter (fn [s] (string/has-prefix? to-expand s))))))
  completions)

# Misc utility functions for end users.

(defn shrink-path
  "Shrink path p following rules:\n
   replace the prefix $HOME/ with ~/"
  [p]
  (let [home (os/getenv "HOME")]
    (cond
      (string/has-prefix? (string home "/") p)
      (string/replace home "~" p)
      (= home p) "~"
      p)))

(defn in-env*
  "Function form of in-env."
  [env-vars f]
  (let [old-vars @{}]
    (each k (keys env-vars)
      (def new-v (env-vars k))
      (def old-v (os/getenv k))
      (when (string? new-v)
        (put old-vars k (if old-v old-v :unset))
        (os/setenv k new-v)))
    (var haderr false)
    (var err nil)
    (var result nil)
    (try
      (set result (f))
      ([e] (set haderr true) (set err e)))
    (each k (keys old-vars)
      (def old-v (old-vars k))
      (os/setenv k (if (= old-v :unset) nil old-v)))
    (when haderr
      (error err))
    result))

(defmacro in-env
  "Run forms with os environment variables set
   to the keys and values of env-vars. The os environment
   is restored before returning the result."
  [env-vars & forms]
  (tuple in-env* env-vars (tuple 'fn [] ;forms)))
