lvs: generate_run_file
	rm -rf ./run
	mkdir -p ./run
	cd ./run && \
	source ../lvs.sh
	cd ..

generate_run_file:
	. ./generate_lvs_run_file.sh

view-lvs: 
	. ./view-lvs.sh

clean:
	rm -rf ./run
	rm -f ./lvs_run_file
