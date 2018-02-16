REBAR=rebar3
CC=clang
CCFLAGS=-framework CoreFoundation -framework CoreMIDI -Wall -Weverything -O0


.PHONY: compile deps all clean


all: compile


compile:
	$(REBAR) compile


deps:
	$(REBAR) get-deps


clean:
	-rm priv/ecm-device priv/ecm-virtualdevice priv/ecm-list-devices


priv/%: c_src/%.c
	-mkdir priv
	$(CC) $(CCFLAGS) -o $@ $<
