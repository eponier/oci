
sinclude .config

OCAMLFIND_INSTALL_DIR=$(shell ocamlfind printconf destdir)/oci
LIB_INSTALL_DIR ?= $(OCAMLFIND_INSTALL_DIR)
PREFIX ?= /usr/local

PACKAGES=async fileutils ppx_core ppx_bin_prot ppx_sexp_conv async_shell extunix core core_extended textutils cmdliner ppx_compare ppx_fields_conv ppx_here
# I don't understand warning 18
OCAML_WARNING=+a-4-9-18-41-30-42-44-40
OCAML_WARN_ERROR=+5+10+8+12+20+11
OPTIONS=-no-sanitize -no-links -tag debug -use-ocamlfind	\
-cflags -w,$(OCAML_WARNING) -cflags				\
-warn-error,$(OCAML_WARN_ERROR) -cflag -bin-annot -j 8 -tag thread		\
 -tag principal
#OPTIONS += -cflags -warn-error,+a
DIRECTORIES=tests src
OCAMLBUILD=ocamlbuild \
		 $(addprefix -package ,$(PACKAGES)) \
		 $(OPTIONS)	\
		 $(addprefix -I ,$(DIRECTORIES)) \

.PHONY: tests monitor.native tests_table.native tests_table.byte

INTERNAL_BINARY=Oci_Copyhard Oci_Default_Master	\
	Oci_Wrapper  Oci_Cmd_Runner Oci_Simple_Exec  \
	Oci_Generic_Masters_Runner

EXTERNAL_BINARY=Oci_Monitor
#For testing the library
EXTERNALLY_COMPILED_BINARY=oci_default_master oci_default_client

BINARY=$(INTERNAL_BINARY) $(EXTERNAL_BINARY)

LIBRARY=Oci_Master Oci_Runner Oci_Client

TESTS_TMP = soprano_client bf_client
TESTS = tests_runner launch_test

LIB= Oci_Common.cmi Oci_Filename.cmi Oci_Std.cmi Oci_pp.cmi		\
	Oci_Default_Masters.cmxa Oci_Default_Masters.a			\
	Oci_Generic_Masters.cmi Oci_Generic_Masters_Api.cmi		\
	Oci_Rootfs.cmi Oci_Rootfs_Api.cmi Oci_Cmd_Runner_Api.cmi	\
	$(addsuffix .cmxa, $(LIBRARY)) 					\
	$(addsuffix .cmi, $(LIBRARY)) 					\
	$(addsuffix .a,	$(LIBRARY))

TOCOMPILE= $(addprefix src/, $(addsuffix .native,$(BINARY)) $(LIB)) \
	$(addprefix tests/, $(addsuffix .native,$(TESTS) $(TESTS_TMP)))

all: compile $(addprefix bin/, $(EXTERNALLY_COMPILED_BINARY))

compile: .merlin src/Oci_Version.ml META
	@rm -rf bin/ lib/
	$(OCAMLBUILD) $(TOCOMPILE)
	@mkdir -m 777 -p bin/
	@mkdir -p lib/oci/
	@cp $(addprefix _build/,$(addprefix src/, $(addsuffix .native, $(BINARY)))) \
	    $(addprefix _build/,$(addprefix tests/, $(addsuffix .native, $(TESTS_TMP)))) \
	    bin
	@cp $(addprefix _build/,$(addprefix src/, $(LIB))) META lib/oci

install:
	rm -rf $(DESTDIR)$(LIB_INSTALL_DIR)/bin
	ocamlfind remove oci
	ocamlfind install oci lib/oci/*
	@mkdir -p $(DESTDIR)$(LIB_INSTALL_DIR)/bin $(DESTDIR)$(PREFIX)/bin
	install $(addprefix bin/, $(addsuffix .native, $(INTERNAL_BINARY))) $(DESTDIR)$(LIB_INSTALL_DIR)/bin
	install bin/oci_default_master $(DESTDIR)$(LIB_INSTALL_DIR)/bin
	install bin/Oci_Monitor.native $(DESTDIR)$(PREFIX)/bin/oci_monitor
	install bin/oci_default_client $(DESTDIR)$(PREFIX)/bin/oci_default_client

uninstall:
	rm -rf $(DESTDIR)$(LIB_INSTALL_DIR)/bin
	ocamlfind remove oci
	rm -f $(DESTDIR)$(PREFIX)/bin/oci_monitor $(DESTDIR)$(PREFIX)/bin/oci_default_client

#force allows to always run the rules that depends on it
.PHONY: force

GIT_VERSION:=$(shell git describe --tags --dirty)

define CONFIG
$(GIT_VERSION)\n\
$(PREFIX)\n\
$(LIB_INSTALL_DIR)
endef

#.config_stamp remember the last config for knowing when rebuilding
.config_stamp: force
	echo "$(CONFIG)" | cmp -s - $@ || echo "$(CONFIG)" > $@


src/Oci_Version.ml: .config_stamp Makefile
	@echo "Generating $@ for version $(GIT_VERSION)"
	@rm -f $@.tmp
	@echo "(** Autogenerated by makefile *)" > $@.tmp
	@echo "let version = \"$(GIT_VERSION)\"" >> $@.tmp
	@echo "let prefix = \"$(PREFIX)\"" >> $@.tmp
	@echo "let lib_install_dir = \"$(LIB_INSTALL_DIR)\"" >> $@.tmp
	@chmod a=r $@.tmp
	@mv -f $@.tmp $@

bin/%.native: src/version.ml force
	@mkdir -p `dirname bin/$*.native`
	@rm -f $@
	@$(OCAMLBUILD) src/$*.native
	@ln -rs _build/src/$*.native $@

monitor.byte:
	$(OCAMLBUILD) src/monitor/monitor.byte

tests_table.byte:
	$(OCAMLBUILD) tests/tests_table.byte


#Because ocamlbuild doesn't give to ocamldoc the .ml when a .mli is present
dep:
	cd _build; \
	ocamlfind ocamldoc -o dependencies.dot $$(find src -name "*.ml" -or -name "*.mli") \
	$(addprefix -package ,$(PACKAGES)) \
	$(addprefix -I ,$(DIRECTORIES)) \
	-dot -dot-reduce
	sed -i -e "s/  \(size\|ratio\|rotate\|fontsize\).*$$//" _build/dependencies.dot
	dot _build/dependencies.dot -T svg > dependencies.svg

clean:
	rm -rf bin src/Oci_Version.ml
	$(OCAMLBUILD) -clean

.merlin: Makefile
	@echo "Generating Merlin file"
	@rm -f .merlin.tmp
	@for PKG in $(PACKAGES); do echo PKG $$PKG >> .merlin.tmp; done
	@for SRC in $(DIRECTORIES); do echo S $$SRC >> .merlin.tmp; done
	@for SRC in $(DIRECTORIES); do echo B _build/$$SRC >> .merlin.tmp; done
	@echo FLG -w $(OCAML_WARNING) >> .merlin.tmp
	@echo FLG -w $(OCAML_WARN_ERROR) >> .merlin.tmp
	@mv .merlin.tmp .merlin

META: .config_stamp Makefile META.in
	@echo "Generating META file"
	@rm -f $@.tmp
	@sed -e "s/@(REQUIRES)/$(PACKAGES)/" -e "s/@(VERSION)/$(GIT_VERSION)/" $@.in > $@.tmp
	@mv $@.tmp $@


# We test that the library contains the needed modules
bin/%:tests/library/%.ml force compile
	OCAMLPATH=lib:$(OCAMLPATH) \
	ocamlfind ocamlopt -thread -linkpkg -package oci.$(patsubst oci_default_%,%,$*) $< -o $@
