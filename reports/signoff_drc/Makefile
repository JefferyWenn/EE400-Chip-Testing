drc: generate_run_file
	rm -rf ./run
	mkdir -p ./run
	mkdir -p ./run/db
	mkdir -p ./run/rpt
	cd ./run && \
	source ../drc.sh
	cd ..

generate_run_file:
	. ./generate_drc_run_file.sh

view-drc: 
	. ./view-drc.sh

clean:
	rm -rf ./run
	rm -f drc_run_file*
