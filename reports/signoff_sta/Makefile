sta: generate_run_file
	rm -rf ./run
	mkdir -p ./run
	cd ./run && \
	source ../sta.sh
	cd ..

generate_run_file:
	. ./generate_timing_tcl.sh

clean:
	rm -rf ./run
	rm ./timing.tcl
