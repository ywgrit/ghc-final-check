Description: Add kfreebsdgnu to GHC_CONVERT_OS in aclocal.m4
Author: Svante Signell <svante.signell@gmail.com>
Bug-Debian: https://bugs.debian.org/913140

Index: b/m4/ghc_convert_os.m4
===================================================================
--- a/m4/ghc_convert_os.m4
+++ b/m4/ghc_convert_os.m4
@@ -26,7 +26,7 @@ AC_DEFUN([GHC_CONVERT_OS],[
         $3="mingw32"
         ;;
       # As far as I'm aware, none of these have relevant variants
-      freebsd|dragonfly|hpux|linuxaout|kfreebsdgnu|freebsd2|darwin|nextstep2|nextstep3|sunos4|ultrix|haiku)
+      freebsd|dragonfly|hpux|linuxaout|freebsd2|darwin|nextstep2|nextstep3|sunos4|ultrix|haiku)
         $3="$1"
         ;;
       msys)
@@ -46,6 +46,9 @@ AC_DEFUN([GHC_CONVERT_OS],[
                 #      i686-gentoo-freebsd8.2
         $3="freebsd"
         ;;
+      kfreebsd*)
+        $3="kfreebsdgnu"
+        ;;
       nto-qnx*)
         $3="nto-qnx"
         ;;
