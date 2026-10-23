# host tests: build on macOS with the system sdk, run with `make -C Tests`

CC = xcrun clang
SRC = main.m ParserTests.m GuardrailTests.m ToolInputTests.m \
	../Frameworks/System/HTTPResponseParser.m \
	../Frameworks/Tools/Guardrails.m \
	../Frameworks/Tools/ToolInputCheck.m
CFLAGS = -fno-objc-arc -Wall -Wextra -Wno-unused-parameter -Werror \
	-fsanitize=address,undefined -g \
	-I. -I../Frameworks/System -I../Frameworks/Tools

test: run_tests
	./run_tests

run_tests: $(SRC) $(wildcard *.h) ../Frameworks/System/*.h ../Frameworks/Tools/*.h
	$(CC) $(CFLAGS) -framework Foundation -o $@ $(SRC)

clean:
	rm -f run_tests

.PHONY: test clean
