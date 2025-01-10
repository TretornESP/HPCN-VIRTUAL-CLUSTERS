#!/bin/bash

pushd () {
    command pushd "$@" > /dev/null
}

popd () {
    command popd "$@" > /dev/null
}

bye () {
	echo $1
	exit
}

check_job_status () {
	squeue --job $1 --noheader
}

build () {
	# Check if the repository is already downloaded
	if [ -d "NPB3.4.3" ]; then
		echo "Tests already downloaded"
	else
		echo "Downloading tests"
		wget https://www.nas.nasa.gov/assets/npb/NPB3.4.3.tar.gz -O NPB3.4.3.tar.gz
		tar -xvf NPB3.4.3.tar.gz
		rm NPB3.4.3.tar.gz
	fi

	pushd NPB3.4.3/NPB3.4-MPI

	#Create the make.def file
	#Compile only CG and LU benchmarks in C language
	cp config/make.def.template config/make.def
	echo "WTIME = wtime.c" >> config/make.def

	#suite.def parser is trash, so here we are, manually
	#replacing cg and lu to B kind..
	cp config/suite.def.template config/suite.def
	#This is black magic mostly..
	sed -i -E 's/^(cg|lu)\t[SWABCDE]/\1\tB/' config/suite.def

	#Compile the benchmarks
	if [ -d "./bin" ]; then
		echo "Binaries already exist, deleting"
		rm ./bin/*
	fi

	make clean
	make -j suite

	if [ "./bin/lu.B.x" ]; then
		echo "lu B test created successfully"
	else
		echo "Error, lu b test was not compiled"
	fi

	if [ "./bin/cg.B.x" ]; then
		echo "cg B test created successfully"
	else
		echo "Error, cg b test was not compiled"
	fi

	rm ./bin/*.S.x

	mkdir -p /nfs/mpi/npbinaries
	mv ./bin/*.B.x /nfs/mpi/npbinaries

	popd
}

execute () {
	pushd ./npbinaries
	echo \#\!/bin/bash > ./$1_$2.sh
	echo \# >> ./$1_$2.sh
	echo \#SBATCH --job-name=$1_$2 >> ./$1_$2.sh
	echo \#SBATCH --output=/nfs/mpi/npbinaries/$1_$2_$4.out >> ./$1_$2.sh
	echo \#SBATCH --partition=aws >> ./$1_$2.sh
	echo \# >> ./$1_$2.sh
	echo \#SBATCH --time=10:00 >> ./$1_$2.sh
	echo mpirun /nfs/mpi/npbinaries/$1 >> ./$1_$2.sh

	echo "Giving time to the NFS to replicate... 5 sec"
	sleep 5
	echo "Executing test $1 with $2 nodes and $3 tasks-per-node"
	JOB_ID=$(sbatch -N $2 --ntasks-per-node $3 ./$1_$2.sh | awk '{print $4}')
	
	echo Submitted job $JOB_ID

	while true; do
		JOB_STATUS=$(check_job_status $JOB_ID)

		if [ -z "$JOB_STATUS" ]; then
			echo "Job $JOB_ID has finished"
			break
		else
			echo "Waiting for job $JOB_ID to complete this may take a while..."
		fi
		sleep 10
	done

	popd
}

results () {
	CHECK=$(cat /nfs/mpi/npbinaries/$1_$2_$3.out | grep "Verification" | grep "SUCCESSFUL")

	if [ -z "$CHECK" ]; then
		bye "Error, verificacin invalida para /nfs/mpi/npbinaries/$1_$2_$3.out"
	fi

	cat /nfs/mpi/npbinaries/$1_$2_$3.out | grep "Time in seconds" | awk '{print $5}'
}

iterator () {
	echo "Running $4 times test $1 with $2 nodes, $3 tasks per node and generating average"
	echo "Report folder: /nfs/mpi/reports/$5"

	sum=0
	count=$4

	for ((i=1; i<=count; i++)); do
		#execute [binary name] [nodes] [tasks (do not change)] [iteration]
		execute $1 $2 $3 $i
		sleep 2
		result=$(results $1 $2 $i)
		echo "Iteration $i took $result seconds"
		cp /nfs/mpi/npbinaries/$1_$2_$i.out /nfs/mpi/reports/$5/$1_$2_$i.out
		sum=$(echo "$sum + $result" | bc)
	done

	average=$(echo "$sum / $count" | bc -l)

    sleep 2
	echo "Average time for test is $average"
	echo "[KERNEL: $1 NODES: $2 TPN: $3 ITERATIONS: $4] AVG: $average" >> /nfs/mpi/reports/$5/report.txt
}

startup () {
	echo "NPB Experiments for HPCN"
	echo "By Xabier Iglesias # xabier.iglesias.perez@udc.es"
 
	# Check if the mpicc command is available
	if ! command -v mpicc &> /dev/null
	then
		bye "mpicc command could not be found"
	fi

	# Check if wget command is available
	if ! command -v wget &> /dev/null
	then
		bye "wget command could not be found"
	fi

	#Check if tar command is available
	if ! command -v tar &> /dev/null
	then
		bye "tar command could not be found"
	fi

	# Check if the folder /nfs/mpi exists, if so pushd to it
	if [ ! -d "/nfs/mpi" ]; then
		bye "Directory /nfs/mpi does not exist"
		exit
	fi

	cd /nfs/mpi
	datetime=$(date +"%Y-%m-%d_%H-%M-%S")

	if [ ! -f ./npbinaries/lu.B.x ] || [ ! -f ./npbinaries/cg.B.x ]; then
		echo "Test do not exist, building..."
		build
	fi
	if [ ! -f ./npbinaries/lu.B.x ] || [ ! -f ./npbinaries/cg.B.x ]; then
        bye "Error, tests could not be built"
    fi
	echo "Executing tests!"
	mkdir -p /nfs/mpi/reports/$datetime/
	touch /nfs/mpi/reports/$datetime/report.txt
	#iterator [kernel name] [nodes] [tasks per node (do not touch!)] [iterations]
	iterator lu.B.x 1 2 5 $datetime
	iterator cg.B.x 1 2 5 $datetime
	iterator lu.B.x 2 2 5 $datetime
	iterator cg.B.x 2 2 5 $datetime
	iterator lu.B.x 4 2 5 $datetime
	iterator cg.B.x 4 2 5 $datetime
	iterator lu.B.x 8 2 5 $datetime
	iterator cg.B.x 8 2 5 $datetime

	bye "Finished execution of tests, saved to /nfs/mpi/reports/$datetime/report.txt"

}

startup
