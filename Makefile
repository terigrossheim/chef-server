LIBDIR=$(CURDIR)/lib
DEPS=$(CURDIR)/deps
PLT_DIR=$(CURDIR)/.plt
PLT=$(PLT_DIR)/dialyzer_plt
REBAR=$(shell which rebar)

ERLPATH= -pa $(DEPS)/webmachine/ebin -pa $(DEPS)/covertool/ebin \
	-pa $(DEPS)/erlsom/ebin -pa $(DEPS)/iso8601/ebin \
	-pa $(DEPS)/mini_s3/ebin -pa $(DEPS)/mochiweb/ebin \
	-pa $(DEPS)/ibrowse/ebin

ifeq ($(REBAR),)
	$(error "Rebar not available on this system")
endif

.PHONY: all deps compile test eunit ct rel/bookshelf rel doc build-plt \
	check-plt clean-plt

all: compile eunit dialyzer

clean:
	@$(REBAR) skip_deps=true clean
	@rm -rf ebin_dialyzer
#	rebar does not clean up common test logs
	@rm -rf $(CURDIR)/lib/bookshelf_wi/logs

clean_plt:
	rm -rf $(PLT_DIR)

distclean: clean clean-plt
	@rm -rf deps

allclean:
	@$(REBAR) clean

update: compile
	@cd rel/bookshelf

compile: $(DEPS)
	@$(REBAR) compile

$(PLT):
	mkdir -p $(PLT_DIR)
	- dialyzer --build_plt --output_plt $(PLT) \
		$(ERLPATH) \
		--apps erts kernel stdlib eunit compiler crypto \
		webmachine inets ibrowse iso8601 mini_s3 mochiweb \
		xmerl erlsom
	@if test ! -f $(PLT); then exit 2; fi


dialyzer: $(PLT)
	@$(REBAR) compile
	dialyzer -nn --no_check_plt -Wno_undefined_callbacks --src --plt $(PLT) \
	$(ERLPATH) \
	-pa $(LIBDIR)/bookshelf_wi/ebin \
	-c $(LIBDIR)/bookshelf_wi/src

$(DEPS):
	@$(REBAR) get-deps

eunit: compile
	$(REBAR) skip_deps=true eunit

ct : eunit
	rm -rf /tmp/bukkits
	mkdir -p /tmp/bukkits
	ERL_LIBS=`pwd`/deps:`pwd`/lib:$(ERL_LIBS) $(REBAR) skip_deps=true ct

test: ct eunit

rel/bookshelf:
	$(REBAR) generate

rel: compile rel/bookshelf

devrel: rel
	@/bin/echo -n Symlinking deps and apps into release
	@$(foreach dep,$(wildcard deps/*), /bin/echo -n .;rm -rf rel/bookshelf/lib/$(shell basename $(dep))-* \
	   && ln -sf $(abspath $(dep)) rel/bookshelf/lib;)
	@$(foreach app,$(wildcard lib/*), /bin/echo -n .;rm -rf rel/bookshelf/lib/$(shell basename $(app))-* \
	   && ln -sf $(abspath $(app)) rel/bookshelf/lib;)
	@/bin/echo done.
	@/bin/echo  Run \'make update\' to pick up changes in a running VM.

relclean:
	@rm -rf rel/bookshelf
