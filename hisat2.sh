#!/usr/bin/env bash
#SBATCH -n 8
#SBATCH -N 1
#SBATCH -t 5-0

module add bbmap hisat2 subread samtools

###############################################################################
# Basic pipeline for mapping and counting single/paired end reads using hisat2
# Run this script on LongLeaf
###############################################################################

###############################################################################
# Hard variables
###############################################################################

#       hisat2 indices
index="/nas02/home/s/f/sfrenk/proj/seq/WS251/genome/hisat2/genome"

#       gtf annotation file for genes
gtf="/nas02/home/s/f/sfrenk/proj/seq/WS251/genes.gtf"

#       gtf annotation file for repeats
rmsk_gtf="/proj/ahmedlab/steve/seq/transposons/ce11_rebpase/ce11_rmsk_original.gtf"

###############################################################################
###############################################################################


usage="
    Basic pipeline for mapping and counting single/paired end reads using hisat2

    USAGE
       step1:   load the following modules: trim_galore hisat2 samtools subread
       step2:   bash hisat2_genome.sh [options]  

    ARGUMENTS
        -d/--dir
        Directory containing read files (fastq.gz format).

        -p/--paired
        Use this option if fastq files contain paired-end reads. NOTE: if paired, each pair must consist of two files with the basename ending in '_1' or '_2' depending on respective orientation.

        -t/--trim
        Trim reads with trim_galore before mapping. If using this option, also supply the adapter sequence.
    "

# Set default parameters
paired=false
multihits=1
trim=false

# Parse command line parameters

if [ -z "$1" ]; then
    echo "$usage"
    exit
fi


while [[ $# > 0 ]]
do
    key="$1"
    case $key in
        -d|--dir)
        dir="$2"
        shift
        ;;
        -p|--paired)
        paired=true
        ;;
        -t|--trim)
        trim=true
        adapter="$2"
        shift
        ;;
    esac
shift
done

# Remove trailing "/" from input directory if present

if [[ ${dir:(-1)} == "/" ]]; then
    dir=${dir::${#dir}-1}
fi

# Print run parameters to file

if [ -e "run_parameters.txt" ]; then
    rm "run_parameters.txt"
fi

printf "$(date +"%m-%d-%Y_%H:%M")\n\nPipeline: hisat2\n\nParameters:sample directory: ${dir}\n\tpaired end: ${paired}\n\ttrim: ${trim} apadter=${adapter}\n" > run_parameters.txt

module list &>> run_parameters.txt

###############################################################################
###############################################################################

# Prepare directories

if [ ! -d "trimmed" ] && [[ $trim = true ]]; then
    mkdir trimmed
fi

if [ ! -d "hisat2_out" ]; then
    mkdir hisat2_out
fi

if [ ! -d "bam" ]; then
    mkdir bam
fi

if [ ! -d "count" ]; then
    mkdir count
fi

if [ -e "total_mapped_reads.txt" ]; then
    rm "total_mapped_reads.txt"
fi

echo "$(date +"%m-%d-%Y_%H:%M") Starting pipeline"

for file in ${dir}/*.fastq.gz; do
    
    skipfile=false

    if [[ $paired = true ]]; then
            
        # paired end

        if [[ ${file:(-11)} == "_1.fastq.gz" ]]; then
        
            Fbase=$(basename $file .fastq.gz)
            base=${Fbase%_1}

            printf "\n\t"$base >> run_parameters.txt

            if [[ $trim = true ]]; then

                # Trim reads

                echo "$(date +"%m-%d-%Y_%H:%M") Trimming ${base} with bbduk..."
                
                bbduk.sh in1=${dir}/${base}_1.fastq.gz in2=${dir}/${base}_2.fastq.gz out1=./trimmed/${base}_1.fastq.gz out2=./trimmed/${base}_2.fastq.gz literal=${adapter} ktrim=r overwrite=true k=23 mink=11 hdist=1 tpe tbo

                fastq_r1="./trimmed/${base}_1.fastq.gz"
                fastq_r2="./trimmed/${base}_1.fastq.gz"
            else

                fastq_r1="${dir}/${base}_1.fastq.gz"
                fastq_r2="${dir}/${base}_2.fastq.gz"
            fi

            # Map reads using hisat2

            echo "$(date +"%m-%d-%Y_%H:%M") Mapping ${base} with hisat2... "        
            hisat2 --max-intronlen 12000 --no-mixed -p $SLURM_NTASKS -x ${index} -1 $fastq_r1 -2 $fastq_r2 -S ./hisat2_out/${base}.sam

        else

            # Avoid double mapping by skipping the r2 read file
                
            skipfile=true
        fi
    else

        # Single end

        base=$(basename $file .fastq.gz)

        printf "\n\t"$base >> run_parameters.txt

        if [[ $trim = true ]]; then

            # Trim reads

            echo "$(date +"%m-%d-%Y_%H:%M") Trimming ${base} with bbduk..."

            bbduk.sh in=${file} out=./trimmed/${base}.fastq.gz literal=${adapter} ktrim=r overwrite=true k=23 mink=11 hdist=1 tpe tbo

            fastq_file="./trimmed/${base}.fastq.gz"

        else

            fastq_file="${file}"
        fi

        # Map reads using hisat2

        echo "$(date +"%m-%d-%Y_%H:%M") Mapping ${base} with hisat2... "        
        hisat2 --max-intronlen 12000 --no-mixed -p $SLURM_NTASKS -x ${index} -U $fastq_file -S ./hisat2_out/${base}.sam
    fi

    if [[ $skipfile = false ]]; then

        echo "$(date +"%m-%d-%Y_%H:%M") Mapped ${base}"

        echo "$(date +"%m-%d-%Y_%H:%M") Sorting and indexing ${base}.bam"

        # Get rid of unmapped reads

        samtools view -h -F 4 ./hisat2_out/${base}.sam > ./bam/${base}.bam

        # Sort and index

        samtools sort -o ./bam/${base}_sorted.bam ./bam/${base}.bam

        samtools index ./bam/${base}_sorted.bam

        rm ./hisat2_out/${base}.sam
        rm ./bam/${base}.bam

        # Extract number of mapped reads

        total_mapped="$(samtools view -c ./bam/${base}_sorted.bam)"
        printf ${base}"\t"${total_mapped}"\n" >> total_mapped_reads.txt
    fi
done

echo "$(date +"%m-%d-%Y_%H:%M") Counting reads with featureCounts... "

# Count all files together so the counts will appear in one file

ARRAY=()

for file in ./bam/*_sorted.bam
do

    ARRAY+=" "${file}

done

# Count genes

featureCounts -a $gtf -o ./count/counts.txt -T 4 -t exon -Q 30 -g gene_name${ARRAY}

# Count transposons/repeats

featureCounts -a $rmsk_gtf -o ./count/repeat_counts.txt -T 4 -t exon -M --primary${ARRAY}
