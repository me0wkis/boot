NASM ?= nasm
SRC  = src
OUT  = build

all: $(OUT)/stage1.bin $(OUT)/stage2.bin $(OUT)/demo_os.bin

$(SRC)/data.inc: tools/gen_data.py
	python3 tools/gen_data.py

$(OUT)/stage1.bin: $(SRC)/stage1.asm $(SRC)/config.inc
	@mkdir -p $(OUT)
	$(NASM) -f bin -I$(SRC)/ -o $@ $<

$(OUT)/stage2.bin: $(SRC)/*.asm $(SRC)/config.inc $(SRC)/data.inc
	@mkdir -p $(OUT)
	$(NASM) -f bin -I$(SRC)/ -o $@ $(SRC)/stage2.asm

$(OUT)/demo_os.bin: demo/demo_os.asm
	@mkdir -p $(OUT)
	$(NASM) -f bin -o $@ $<

clean:
	rm -rf $(OUT)

.PHONY: all clean
