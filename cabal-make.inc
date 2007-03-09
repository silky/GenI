########################################################################
#
# cabal-make -- an assistant for Haskell projects
#
# Version 0.1
#
# See http://haskell.org/haskellwiki/cabal-make
# 
# Copyright 2007 by Conal Elliott; BSD3 license.
# 
########################################################################

# Default target
build:

#### Default settings.  To override, define before including this file.

# Pass to "./setup configure"
configure-args ?= \
	$(configure-dirs) \
        --haddock-args="$(foreach iface,$(haddock-interfaces),--read-interface=$(iface)) $(source-args) $(comments-args)"
show-configure-args:
	@echo $(configure-args)

# Generate links to colorized source code.  See source-args comment below.
source-args ?= \
	  --source-module=src.%{MODULE}.hs.html \
	  --source-entity=%{FILE///.}.html\#%{NAME}

## Where to place the comments.
#comments ?= http://haskell.org/haskellwiki/Talk:$(package)/Library
#
## Generate links to user comment pages
#comments-args ?= \
#	  --comments-base=$(comments) \
#	  --comments-module=$(comments)/%{MODULE/.//}

# The package's home on the web.
package-home ?= darcs.haskell.org:/home/darcs/packages/$(package)

# For test-get-build
tmp-dir ?= c:/tmp

# The user name above is for the make target "webdoc", which uses scp to copy
# your documentation to darcs.haskell.org.
user ?= UnknownUser

# Package name.   Extract from cabal file.
package ?= $(strip $(shell cat *.cabal | egrep -i 'name:' | sed -e 's/name://'))
show-package:
	@echo $(package)

# Extract modules from $(package).cabal.
modules = $(strip $(shell egrep '^[ \t]+[A-Z][0-9A-Za-z.]+[^.][ \t]*$$' *.cabal))
show-modules:
	@echo $(modules)


# For seeing generated docs and setting up comment watch.
BROWSER ?= firefox

# source-args comment:
# 
# Note: (a) no project-level source link (--source-base), and (b)
# hscolour'd source code is generated at "dist/src.Foo.Bar.hs.html".  I
# prefer (a) project-level source link and (b) "dist/src/Foo.Bar.hs.html",
# but I don't know how to get haddock to keep the first slash and replace
# the others.  I took out the --source-base rather than link to a
# directory that mixes hscolour'd code and haddock docs.  Better solution:
# add a hscolour flag for the hscolour.css file location, and put the
# sources back into a tree with links to that file.  I don't know how to
# construct the necessary relative references, which would be something
# like "../../hscolour.css".  Another idea: add per-source-directory
# symlinks to the shared CSS.  Simple but less browser-cache-friendly.  I
# don't know how to make this idea work either, since I don't know how to
# make real symlinks in my cygwin environment.

#### Rules

all:  configure build doc install

configure: .setup-config

build: .setup-config
	./setup build

install: build
	./setup install

doc: doc-clean haddock

hasktags:
	hasktags *.cabal `find src -name '*.*hs'`

clean:
	rm -rf dist
	rm -f .setup-config .installed-pkg-config ./setup.exe `find . -name '*.hi' -o -name '*.o'`

version ?= $(strip $(shell cat *.cabal | egrep -i 'version:' | sed -e 's/version://I'))

show-version:
	@echo $(version)

show-config-args:
	@echo haddock-interfaces=$(configure-args)

setup: Setup.*hs
	ghc --make Setup.*hs -o setup

# setup with my own (Windows-friendly) preferences.  You'll probably want
# to use "make setup; ./setup configure" instead.  I've avoided using
# $(package).cabal here, in case the package & Cabal names differ, such as
# "monads" vs "monadLib".  If Cabal relaxes the one-cabal-file
# restriction, revisit.
.setup-config: setup *.cabal
	./setup configure $(configure-args)
	sed -e 's/\\\\/\//g' < .setup-config > .tmp.setup-config
	mv .tmp.setup-config .setup-config

# The previous two lines provide a workaround for a strange problem on
# Windows.  The forward slashes in that file all get changed to
# backslashes.  The difficulty is that some of those slashes are part of
# URLs rather than file paths.  The sed & mv restore the back-slashes.
# This workaround works fine for cygwin.  I haven't tried under msys.


# modules with "." replaced by "/"
slash-modules = $(subst .,/,$(modules))
show-slash-modules:
	@echo $(slash-modules)

# Massage module names into source file names.
sources = $(patsubst %,src/%.hs,$(slash-modules))
show-sources:
	@echo $(sources)

# Modify sources to use the unix end-of-line convention rather than dos.
unixify-sources:
	touch CHANGES TODO
	dos2unix README CHANGES Makefile TODO *.cabal `find src -name '*.*hs'`

# Or for docs (probably not worth bothering)
unixify-docs:
	dos2unix `find dist/doc/html -name '*.html'`

# Similarly to get the dos end-of-line convention.
dosify-sources:
	unix2dos README CHANGES Makefile TODO *.cabal `find src -name '*.*hs'`

# Remove old docs first, in case some modules have been renamed or deleted.
doc-clean:
	rm -rf dist/doc

## Add syntax-coloring and anchors to sources.  Use CSS and copy in $(hscolour-css).
#hscolour:
#	mkdir -p dist/doc/html
#	cp $(hscolour-css) dist/doc/html
#	$(foreach file, $(sources),\
#	   HsColour -css -anchor $(file) > dist/doc/html/$(subst /,.,$(basename $(file))).hs.html; )

# Generate Haddock docs.  See variables source-args, comments, and comment-args
haddock: .setup-config
	./setup haddock

# Make a new repo (requires account)
darcs-repo:
	darcs put $(user)@darcs.haskell.org:/home/darcs/packages/$(package)

# Tag with current version
darcs-tag:
	darcs tag $(version)

# Make a tarball and copy to server.
darcs-dist:
	darcs dist -d $(package)-$(version)
	ssh $(user)@darcs.haskell.org "mkdir -p /home/darcs/packages/$(package)/dist"
	scp $(package)-$(version).tar.gz $(user)@darcs.haskell.org:/home/darcs/packages/$(package)/dist/
	mkdir -p tarballs
	mv $(package)-$(version).tar.gz tarballs

# After "darcs record" and "darcs push", see if everything works
test-get-build:
	cd $(tmp-dir); \
	rm -rf $(package); \
	darcs get http://darcs.haskell.org/packages/$(package); \
	cd $(package); \
	ghc --make Setup.*hs; \
	./setup configure; \
	./setup build

# After "make doc", copy to the server.  Remove old docs first, in case
# some modules have been renamed or deleted.
web-doc:
	ssh $(user)@darcs.haskell.org "rm -rf /home/darcs/packages/$(package)/dist/doc"
	scp -r dist/doc $(user)@$(package-home)

# Check out local or remote docs
see-doc:
	$(BROWSER) dist/doc/html/index.html; echo
see-web-doc:
	$(BROWSER) http://darcs.haskell.org/packages/$(package)/doc/html

# Make & see docs
doc-see: doc see-doc
web-doc-see: web-doc see-web-doc

# Automatically add yourself to the watch list of all project talk pages.
# There's one talk page for the project and one for each module.
watch-comments:
	$(BROWSER) "$(comments)&action=watch" ;\
	for file in $(slash-modules); do \
	  $(BROWSER) "$(comments)/$$file&action=watch"; \
	done; \
	echo Now watching all talk pages for $(package)

