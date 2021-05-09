(in-package :stumpwm)
(set-module-dir "~/.stumpwm.d/modules")
(load-module "stump-radio")
(ql:quickload :swank)


;;
;; Link slime to stump for live editing
;;

;; use prefix : (swank) to start the link and then follow the instructions at the bottom of the command
(defcommand swank () ()
    (swank:create-server :port 4005
                       :style swank:*communication-style*
                       :dont-close t)
  (echo-string (current-screen) 
	       "Starting swank. M-x slime-connect RET RET, then (in-package stumpwm)."))


;;
;; Prefix and modmaps
;;

(run-shell-command "xmodmap -e 'clear mod4'")
(run-shell-command "xmodmap -e 'keycode 133 = Super_L'")
(run-shell-command "xmodmap -e 'add mod4 = Super_L'")

(set-prefix-key (kbd "C-z"))



;;
;; prompt the user for an interactive command
;;

(defcommand colon1 (&optional (initial "")) (:rest)
  (let ((cmd (read-one-line (current-screen) ": " :initial-input initial)))
    (when cmd
      (eval-command cmd t))))



;;
;; Define window placement policy...
;;

;; Clear rules
(clear-window-placement-rules)
;; Last rule to match takes precedence!



;;
;; Groups and Workspaces
;;

(defcommand create-groups () ()
  (loop for group in '("soc" "teams" "dev" "emacs" "games")
	do
	   (if (string= group "steam")
	       (gnewbg-float group)
	       (gnewbg group))))

(defmacro defset-key-selector (name map com)
  `(defcommand ,name () ()
     (loop for x in '(1 2 3 4 5 6)
	   do (define-key ,map (kbd (format nil "s-~a" x)) (format nil "~a ~a" ,com x)))))

(defset-key-selector gselect-keys *top-map* 'gselect)
(defset-key-selector gmove-keys *root-map* 'gmove)

(grename "www")
(create-groups)
(gselect-keys)
(gmove-keys)



;;
;; Volume
;;

;;For the modeline
(defun getvolume ()
  (run-shell-command "amixer get Master | grep 'Front Left' | awk -F'[][]' '{ print $2 }'" t))

(defun mutedp ()
  (let ((command (run-shell-command "amixer get Master | grep 'Front Left' | awk -F '[][]' '{ print $4 }'" t)))
    (subseq command 1 (1- (length command)))))

(defun maybemute (mutedp)
  (if (string= mutedp "off")
      "m"
      ""))


;;Volume keys (default sink because pulse is dumb and changes default sink if you toggle it too much
(define-key *top-map* (kbd "F6") "exec pactl set-sink-volume @DEFAULT_SINK@ +5%")
(define-key *top-map* (kbd "F5") "exec pactl set-sink-volume @DEFAULT_SINK@ -5%")
(define-key *top-map* (kbd "F3") "exec pactl set-sink-mute @DEFAULT_SINK@ toggle")



;;
;; Battery
;;

;; Modeline formatting
(defun bat-zone-color (bat med crit)
      (cond ((>= bat med) 2)
	    ((and (>= bat crit) (< bat med) 3))
	    (t 1)))
0
(defun getbat ()
  (parse-integer (with-open-file (*standard-input* #p"/sys/class/power_supply/BAT0/capacity")(read-line))))

(defun check-battery2 ()
  (bat-zone-color (getbat) 55 25))

(defun chargingquery ()
  (let ((chargingq (with-open-file (*standard-input* #p"/sys/class/power_supply/BAT0/status")(read-line))))
    chargingq))


(defun maybecharge (chargingquery)
  (if (string= chargingquery "Charging")
      "+"
      ""))
      
(defun formatted-bat ()
  (format nil "^~A ~D%" (check-battery2) (getbat)))



;;
;; WIFI SETTINGS
;;

(defvar *iwconfig-path* "/sbin/iwconfig"
  "Location if iwconfig, defaults to /sbin/iwconfig.")

(defvar *wireless-device* nil
  "Set to the name of the wireless device you want to monitor. If set
  to NIL, try to guess.")

(defvar *wifi-modeline-fmt* "%e %p"
  "The default value for displaying WiFi information on the modeline.
@table @asis
@item %%
A literal '%'
@item %e
Network ESSID
@item %p
Signal quality (with percentage sign)
@item %P
Signal quality (without percentage sign)
@end table
")

(defvar *use-colors* t
  "Use colors to indicate signal quality.")

(defun sig-quality-fmt (qual)
  (if *use-colors*
      (bar-zone-color qual 80 60 40 t)
      ""))

(defun wifi-get-essid (pair)
  (let ((essid (car pair)))
    (format nil "~A" essid)))

(defun wifi-get-signal-quality-pc (pair)
  (let ((qual (cdr pair)))
    (format nil "^[~A~D%^]" (sig-quality-fmt qual) qual)))

(defun wifi-get-signal-quality (pair)
  (let ((qual (cdr pair)))
    (format nil "^[~A~D^]" (sig-quality-fmt qual) qual)))

(defvar *wifi-formatters-alist*
  '((#\e wifi-get-essid)
    (#\p wifi-get-signal-quality-pc)
    (#\P wifi-get-signal-quality)))

(defmacro defun-cached (name interval arglist &body body)
  "Creates a function that does simple caching. The body must be
written in a functional style - the value returned is set as the
prev-val."
  (let ((prev-time (gensym "PREV-TIME"))
        (prev-val (gensym "PREV-VAL"))
        (now (gensym "NOW")))
    (multiple-value-bind (body decls docstring)
        (alexandria:parse-body body :documentation t)
      `(let ((,prev-time 0)
             (,prev-val "no link"))
         (defun ,name ,arglist
           ,@(when docstring
               (list docstring))
           ,@decls
           (let ((,now (get-internal-real-time)))
             (when (>= (- ,now ,prev-time)
                       (* ,interval internal-time-units-per-second))
               (setf ,prev-time ,now)
               (setf ,prev-val (progn ,@body)))
             ,prev-val))))))

(defun guess-wireless-device ()
  (or (loop
         for path in (list-directory "/sys/class/net/")
         thereis (let ((device-name (car (last (pathname-directory path)))))
                   (if (probe-file (merge-pathnames (make-pathname :directory '(:relative "wireless"))
                                                    path))
                       device-name
                       nil)))
      (error "No wireless device found.")))

(defun-cached fmt-wifi 5 (ml)
  "Formatter for wifi status. Displays the ESSID of the access point
you're connected to as well as the signal strength. When no valid data
is found, just displays nil."
  (declare (ignore ml))
  (block fmt-wifi
    (handler-case
        (let* ((device (or *wireless-device* (guess-wireless-device)))
               (iwconfig (run-shell-command (format nil "~A ~A 2>/dev/null"
                                                    *iwconfig-path*
                                                    device)
                                            t))
               (essid (multiple-value-bind (match? sub)
                          (cl-ppcre:scan-to-strings "ESSID:\"(.*)\"" iwconfig)
                        (if match?
                            (aref sub 0)
                            (return-from fmt-wifi "no link"))))
               (qual (multiple-value-bind (match? sub)
                         (cl-ppcre:scan-to-strings "Link Quality=(\\d+)/(\\d+)" iwconfig)
                       (declare (ignorable match?))
                       (truncate (float (* (/ (parse-integer (aref sub 0))
                                              (parse-integer (aref sub 1)))
                                           100))))))
          (format-expand *wifi-formatters-alist*
                         *wifi-modeline-fmt*
                         (cons essid qual)))
      ;; CLISP has annoying newlines in their error messages... Just
      ;; print a string showing our confusion.
      (t (c) (format nil "~A" c)))))

;;; Add mode-line formatter

(add-screen-mode-line-formatter #\I #'fmt-wifi)



;;
;; Format the modeline
;;

;; (setf *mode-line-foreground-color* "#33bb5e")
(setf *mode-line-foreground-color* "#66b2b2")
;; (setf *mode-line-background-color* "#444444")
(setf *mode-line-background-color* "#101010")

(setf *screen-mode-line-format*
      (list "|| %g || %v || ^>"
	    "%d  "
	    "[Vol: " 
	    '(:eval (string-trim '(#\newline) (getvolume)))
	    '(:eval (string-trim '(#\newline) (maybemute (mutedp))))
            "]"
	    "  [Signal: %I]"
	    "  [Life:"
	    '(:eval (string-trim '(#\newline) (formatted-bat)))
	    "^]]"
	    '(:eval (string-trim '(#\newline) (maybecharge (chargingquery))))
	    ))


(setf *mode-line-timeout* 1)

(toggle-mode-line (current-screen)
        (current-head))

(setf *window-format* "%m%n%s%c")

(setf *hidden-window-color* "^7")

(setf *wifi-modeline-fmt* "%p")



;;
;;Message & Input Bar
;;

;; (set-fg-color "#33bb5e")
(set-fg-color "#66b2b2")
(set-bg-color "#444444")
(set-border-color "#444444")
(set-win-bg-color "#21252b")
(set-focus-color "#66b2b2")
(set-unfocus-color "#21252b")
(setf *maxsize-border-width* 1)
(setf *transient-border-width* 1)
(setf *normal-border-width* 1)
(set-msg-border-width 10)
(setf *window-border-style* :thin)
(setf *message-window-gravity* :bottom-right)
(setf *message-window-input-gravity* :bottom-right)
(setf *input-window-gravity* :bottom-right)



;;
;; Compositor
;;


(defun hide-all-lower-windows (current last)
  (declare (ignore current last))
  (when (typep (current-group) 'stumpwm::tile-group)
    (mapc (lambda (win)
	    (unless (eq win (stumpwm::frame-window
			     (stumpwm::window-frame win)))
	      (stumpwm::hide-window win)))
	  (group-windows (current-group)))))

(defcommand enable-hiding-lower-windows () ()
	    "Enables hiding lower windows obviously"
	    (add-hook *focus-window-hook* 'hide-all-lower-windows))

(enable-hiding-lower-windows)

(run-shell-command "picom &")



;;
;; Mouse 
;;

(setf *mouse-focus-policy* :sloppy)



;;
;; Misc Key Definitions
;;
    
;; Backlight controls
(define-key *top-map* (kbd "F9") "exec xbacklight -inc 5")
(define-key *top-map* (kbd "F8") "exec xbacklight -dec 5")

;; Screenshooter
(define-key *top-map* (kbd "SunPrint_Screen") "exec xfce4-screenshooter")

;;Super based shortcuts for specific applications
(define-key *top-map* (kbd "s-t") "exec dolphin") 
(define-key *top-map* (kbd "s-f") "exec firefox")
(define-key *top-map* (kbd "s-d") "exec discord")
(define-key *top-map* (kbd "s-x") "exec konsole -e tmux")



;;
;; Window Preferences
;;

(define-frame-preference "soc"
  (0 t t :class "discord"))

(define-frame-preference "teams"
  (0 t t :class "teams"))

(define-frame-preference "dev"
  (0 t t :class "pycharm"))

(define-frame-preference "emacs"
  (0 t t :class "Emacs"))

(define-frame-preference "games"
  (0 t t :class "Steam"))



;;
;; Misc background programs to run on startup
;;

(run-shell-command "feh --bg-scale ~/Pictures/synth.jpg")



;;
;; Radio
;;

(define-key *top-map* (kbd "F7") "radio-start")
(define-key *top-map* (kbd "s-F7") "radio-stop")
(define-key *root-map* (kbd "s-n") "radio-next-station")
(define-key *root-map* (kbd "s-p") "radio-previous-station")

