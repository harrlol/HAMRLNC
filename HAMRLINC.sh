#!/bin/bash
set -u

# Harry Li, University of Pennsylvania & Chosen Obih, University of Arizona
# man page
usage () {
    echo ""
    echo "Usage : sh $0"
    echo ""

    cat <<'EOF'
  ######################################### COMMAND LINE OPTIONS #############################
  REQUIRED:
    -o  <project directory>
    -c  <filenames with key and name>
    -g  <reference genome.fa>
    -i  <reference genome annotation.gff3>
    -l  <read length>

  OPTIONAL: 
    -n  number of threads (default 4)
    -a  [use HISAT2 instead of STAR]        #####Disabled 3/28/24######
    -x  [Genome index directory for HISAT2 by user input]       #####Disabled 3/28/24######
    -d  [input a directory of fastq]
    -b  [HISAT library choice: single: F or R, paired: FR or RF, unstranded: leave unspecified]         #####Disabled 3/28/24######
    -f  [filter]
    -m  [HAMR model]
    -k  [activate modification annotation workflow]
    -p  [activate lncRNA annotation workflow]
    -u  [activate featurecount workflow]
    -G  [attribute used for featurecount, default=gene_id]
    -Q  [HAMR: minimum quality score, default=30]
    -C  [HAMR: minimum coverage, default=10]
    -E  [HAMR: sequencing error, default=0.01]
    -P  [HAMR: maximum p-value, default=1]
    -F  [HAMR: maximum fdr, default=0.05]
    -O  [Panther: organism taxon ID, default 3702]
    -A  [Panther: annotation data set, default GO:0008150]
    -Y  [Panther: test type, default FISHER]
    -R  [Panther: correction type, default FDR]
    -S  [optional path for hamr.py]
    -h  [help message] 
  ################################################# END ########################################
EOF
    exit 0
}


############################################# Define Default Variables #####################################
# hamr related defaults
quality=30
coverage=10
err=0.01
pvalue=1
fdr=0.05
exechamr="/HAMR/hamr.py"
filter="$util"/filter_SAM_number_hits.pl
model="$util"/euk_trna_mods.Rdata

# hamr downstream
json="$util"/panther_params.json
generator="$scripts"/annotationGenerateUnified.R
execpthr="/pantherapi-pyclient/pthr_go_annots.py"

# subprogram activation boolean
run_lnc=false
run_mod=false
run_featurecount=false

# other initialization
threads=4
hisat=false
attribute_fc="gene_id"
#curdir=$(dirname "$0")
hsref=""
fastq_in=""
porg=""
pterm=""
ptest=""
pcorrect=""


######################################################### Grab Arguments #########################################
while getopts ":o:c:g:i:z:l:d:b:v:s:n:O:A:Y:R:fmhQx:CakTtGH:DupEPS:F:" opt; do
  case $opt in
    o)
    out=$OPTARG # project output directory root
    ;;
    c)
    csv=$OPTARG # SRR to filename table
    ;;
    g)
    genome=$OPTARG # reference genome 
    ;;
    i)
    annotation=$OPTARG # reference genome annotation
    ;;
    l)
    length+=$OPTARG # read length 
    ;;
    f)
    filter=$OPTARG
    ;;
    m)
    model=$OPTARG
    ;;
    n)
    threads=$OPTARG
    ;;
    p)
    run_lnc=true
    ;;
    k)
    run_mod=true
    ;;
    u)
    run_featurecount=true
    ;;
    Q)
    quality=$OPTARG
    ;;
    O)
    porg=$OPTARG
    ;;
    G)
    attribute_fc=$OPTARG
    ;;
    A)
    pterm=$OPTARG
    ;;
    Y)
    ptest=$OPTARG
    ;;
    R)
    pcorrect=$OPTARG
    ;;
    d)
    fastq_in=$OPTARG
    ;;
    C)
    coverage=$OPTARG
    ;;
    # b)
    # hisatlib=$OPTARG
    # ;;
    # x)
    # hsref=$OPTARG
    # ;;
    E)
    err=$OPTARG
    ;;
    # a)
    # hisat=true
    # ;;
    P)
    pvalue=$OPTARG
    ;;
    S)
    exechamr="$OPTARG"
    ;;
    H)
    execpthr="$OPTARG"
    ;;
    F)
    fdr=$OPTARG
    ;;
    h)
    usage
    ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
    ;;
    :)
      echo "Option -$OPTARG requires an argument." >&2
      exit 1
    ;;
  esac
done


############################################### Derive Other Variables #########################################
# reassign sample input files, genome and annotation files name and include file paths
user_dir=$(pwd)
genome="$user_dir"/"$genome"
annotation="$user_dir"/"$annotation"
out="$user_dir"/"$out"
csv="$user_dir"/"$csv"

# assigning additional variables
dumpout=$out/datasets
ttop=$((threads/2))
mismatch=$((length*6/100))
overhang=$((mismatch-1))
genomedir=$(dirname "$genome")
last_checkpoint=""

# designate log file, if exist, clear, and have all stdout written
logstart=$(date "+%Y.%m.%d-%H.%M.%S")
logfile=$out/Log_$logstart.log
exec > >(tee -a "$logfile") 2>&1
#below captures only echo...?
#exec 2>&1 1>>$logfile 3>&1


################################################ Subprogram Definitions #########################################
# announces reached checkpoint and updates checkpoint file, or creates txt if it didn't exist
checkpoint () {
    echo "Checkpoint reached: $1"
    echo "$1" > "$out"/checkpoint.txt
}

# is repeated for each accession code found in csv, performs fasterq-dump, fastqc, and trimming; automatic paired-end recognition
fastqGrabSRA () {

  echo "begin downloading $line..." 

  fasterq-dump "$line" -O "$dumpout"/raw --verbose

  # automatically detects the suffix
  echo "$dumpout"/raw/"$line"
  if [[ -f $dumpout/raw/$line"_1.fastq" ]]; then
    suf="fastq"
    PE=true
    echo "$line is a paired-end file ending in .fastq"
  elif [[ -f $dumpout/raw/$line"_1.fq" ]]; then
    suf="fq"
    PE=true
    echo "$line is a paired-end file ending in .fq"
  elif [[ -f $dumpout/raw/$line".fastq" ]]; then
    suf="fastq"
    PE=false
    echo "$line is a single-end file ending in .fastq"
  elif [[ -f $dumpout/raw/$line".fq" ]]; then
    suf="fq"
    PE=false
    echo "$line is a single-end file ending in .fq"
  else
    echo "suffix not recognized, please check your datasets"
    exit 1
  fi

  if [[ "$PE" = false ]]; then  
    echo "[$line] performing fastqc on raw file..."
    fastqc "$dumpout"/raw/"$line"."$suf" -o "$dumpout"/fastqc_results &

    echo "[$line] trimming..."
    trim_galore -o "$dumpout"/trimmed "$dumpout"/raw/"$line"."$suf"

    echo "[$line] trimming complete, performing fastqc..."
    fastqc "$dumpout"/trimmed/"$line""_trimmed.fq" -o "$dumpout"/fastqc_results

    # remove unneeded raw
    rm "$dumpout"/raw/"$line"."$suf"

  else 
    echo "[$line] performing fastqc on raw file..."
    fastqc "$dumpout"/raw/"$line""_1.$suf" -o "$dumpout"/fastqc_results &
    fastqc "$dumpout"/raw/"$line""_2.$suf" -o "$dumpout"/fastqc_results &

    echo "[$line] trimming..."
    trim_galore -o "$dumpout"/trimmed "$dumpout"/raw/"$line""_1.$suf"
    trim_galore -o "$dumpout"/trimmed "$dumpout"/raw/"$line""_2.$suf"

    echo "[$line] trimming complete, performing fastqc..."
    fastqc "$dumpout"/trimmed/"$line""_1_trimmed.fq" -o "$dumpout"/fastqc_results
    fastqc "$dumpout"/trimmed/"$line""_2_trimmed.fq" -o "$dumpout"/fastqc_results

    # remove unneeded raw
    rm "$dumpout"/raw/"$line""_1.$suf"
    rm "$dumpout"/raw/"$line""_2.$suf"
  fi

  echo "[$(date '+%d/%m/%Y %H:%M:%S')] finished processing $line"
  echo ""
}

# is repeated for each local file provided, performs fastqc and trimming; automatic paired-end recognition
fastqGrabLocal () {
    sname=$(basename "$fq")
    tt=$(echo "$sname" | cut -d'.' -f1)
    echo "[$sname] performing fastqc on raw file..."
    fastqc "$fq" -o "$dumpout"/fastqc_results &

    echo "[$sname] trimming..."
    trim_galore -o "$dumpout"/trimmed "$fq" --dont_gzip

    echo "[$sname] trimming complete, performing fastqc..."
    fastqc "$dumpout"/trimmed/"$tt""_trimmed.fq" -o "$dumpout"/fastqc_results
    
    # choosing not to remove user provided raw fastq
}

# called upon completion of each sorted BAM files, takes the file through pre-processing, and performs hamr
hamrBranch () {
    if [[ $currProg == "2" ]]; then
        #filter the accepted hits by uniqueness
        echo "[$smpkey] filtering uniquely mapped reads..."
        samtools view \
            -h "$smpout"/sort_accepted.bam \
            | perl "$filter" 1 \
            | samtools view -bS - \
            | samtools sort \
            -o "$smpout"/unique.bam
        echo "[$smpkey] finished filtering"
        echo ""

        # filtering unique completed without erroring out if this is reached
        echo "3" > "$smpout"/progress.txt
        currProg="3"
    fi

    wait

    if [[ $currProg == "3" ]]; then
        if [[ "$run_mod" = false ]]; then
            echo "[$(date '+%d/%m/%Y %H:%M:%S')] modification annotation functionality suppressed, $smpkey analysis completed."
            exit 0
        else
            #adds read groups using picard, note the RG arguments are disregarded here
            echo "[$smpkey] adding/replacing read groups..."
            gatk AddOrReplaceReadGroups \
                I="$smpout"/unique.bam \
                O="$smpout"/unique_RG.bam \
                RGID=1 \
                RGLB=xxx \
                RGPL=illumina_100se \
                RGPU=HWI-ST1395:97:d29b4acxx:8 \
                RGSM=sample
            echo "[$smpkey] finished adding/replacing read groups"
            echo ""

            # RG finished without exiting
            echo "4" > "$smpout"/progress.txt
            currProg="4"
            fi
    fi 

    wait

    if [[ $currProg == "4" ]]; then
        #reorder the reads using picard
        echo "[$smpkey] reordering..."
        echo "$genome"
        gatk --java-options "-Xmx2g -Djava.io.tmpdir=$smpout/tmp" ReorderSam \
            I="$smpout"/unique_RG.bam \
            O="$smpout"/unique_RG_ordered.bam \
            R="$genome" \
            CREATE_INDEX=TRUE \
            SEQUENCE_DICTIONARY="$dict" \
            TMP_DIR="$smpout"/tmp
        echo "[$smpkey] finished reordering"
        echo ""

        # ordering finished without exiting
        echo "5" > "$smpout"/progress.txt
        currProg="5"
    fi 

    wait

    if [[ $currProg == "5" ]]; then
        #splitting and cigarring the reads, using genome analysis tool kit
        #note can alter arguments to allow cigar reads 
        echo "[$smpkey] getting split and cigar reads..."
        gatk --java-options "-Xmx2g -Djava.io.tmpdir=$smpout/tmp" SplitNCigarReads \
            -R "$genome" \
            -I "$smpout"/unique_RG_ordered.bam \
            -O "$smpout"/unique_RG_ordered_splitN.bam
            # -U ALLOW_N_CIGAR_READS
        echo "[$smpkey] finished splitting N cigarring"
        echo ""

        # cigaring and spliting finished without exiting
        echo "6" > "$smpout"/progress.txt
        currProg="6"
    fi 

    wait

    if [[ $currProg == "6" ]]; then
        #final resorting using picard
        echo "[$smpkey] resorting..."
        gatk --java-options "-Xmx2g -Djava.io.tmpdir=$smpout/tmp" SortSam \
            I="$smpout"/unique_RG_ordered_splitN.bam \
            O="$smpout"/unique_RG_ordered_splitN.resort.bam \
            SORT_ORDER=coordinate
        echo "[$smpkey] finished resorting"
        echo ""

        # cigaring and spliting finished without exiting
        echo "7" > "$smpout"/progress.txt
        currProg="7"
    fi 

    wait

    if [[ $currProg == "7" ]]; then
        #hamr step, can take ~1hr
        echo "[$smpkey] hamr..."
        #hamr_path=$(which hamr.py) 
        python $exechamr \
            -fe "$smpout"/unique_RG_ordered_splitN.resort.bam "$genome" "$model" "$smpout" $smpname $quality $coverage $err H4 $pvalue $fdr .05
        wait

        if [ ! -e "$smpout/${smpname}.mods.txt" ]; then 
            cd "$hamrout" || exit
            printf '%s \n' "$smpname" >> zero_mod.txt
            cd || exit
        else
        # HAMR needs separate folders to store temp for each sample, so we move at the end
            cp "$smpout"/"${smpname}".mods.txt "$hamrout"
        fi
        echo "8" > "$smpout"/progress.txt
        currProg="8"
    fi
}

# called upon completion of each sorted BAM files, takes the sorted BAM through lncRNA prediction pipeline
lncCallBranch () {

    #########################################
    echo "entering lncRNA annotation pipeline..."
    
    # turn bam into gtf
    stringtie "$smpout"/Aligned.sortedByCoord.out.bam \
    -G $annotation \
    -o "$smpout"/stringtie_out.gtf \
    -f 0.05 \
    -j 9 \
    -c 7 \
    -s 20

    # merge gtf from bam with ref gtf
    stringtie --merge -G $annotation \
    -o "$smpout"/stringtie_merge_out.gtf \
    "$smpout"/stringtie_out.gtf

    gffcompare -r $annotation "$smpout"/stringtie_merge_out.gtf

    awk '$7 != "." {print}' "$smpout"/gffcmp.annotated.gtf > "$smpout"/filtered_gffcmp.annotated.gtf

    grep -E 'class_code "u";|class_code "x";' "$smpout"/filtered_gffcmp.annotated.gtf > "$smpout"/UXfiltered_gffcmp.annotated.gtf
    
    samtools faidx $genome

    gffread "$smpout"/UXfiltered_gffcmp_annotated.gtf -T -o "$smpout"/UXfiltered_gffcmp_annotated.gff3

    # why this step????? come back later
    gffread "$smpout"/UXfiltered_gffcmp_annotated.gtf -g $genome -w "$smpout"/transcripts.fa

    # get directory access here, come back later
    python CPC2/bin/CPC2.py -i "$smpout"/transcripts.fa -o "$smpout"/cpc2_output

    awk '$7 < 0.5' "$smpout"/cpc2_output.txt > "$smpout"/filtered_transcripts.txt

    inputFile="$smpout/filtered_transcripts.txt"
    gtfFile="$smpout/UXfiltered_gffcmp_annotated.gtf"
    outputFile="$smpout/cpc_filtered_transcripts.txt"
    while IFS= read -r line; do
        pattern=$(echo "$line" | cut -f1)
        grep "$pattern" "$gtfFile" >> "$outputFile"
    done < "$inputFile"

    gffread "$smpout"/cpc_filtered_transcripts.txt -g $genome "$smpout"/-w rfam_in.fa

    # is the directory correct here...?
    cmscan --nohmmonly \
    --rfam --cut_ga --fmt 2 --oclan --oskip \
    --clanin "$smpout"/Rfam.clanin -o "$smpout"/my.cmscan.out --tblout "$smpout"/my.cmscan.tblout "$smpout"/Rfam.cm "$smpout"/rfam_in.fa

    # tblout info extraction 
    inputFile="$smpout/my.cmscan.tblout"
    gtfFile="$smpout/cpc_filtered_transcripts.txt"
    outputFile="$smpout/rfam_filtered_transcripts.txt"

    # first two line always skip
    # note the python script is susceptible to empty hits, debug as we go
    tail -n +3 "$inputFile" >> "$smpout"/parsed_rfam_out.tblout


    # created a python script to deal with infernal's space delimited file
    cp "$smpout/cpc_filtered_transcripts.txt" "$smpout/rfam_filtered_transcripts.txt"
    while IFS= read -r line; do
        if [[ $line =~ ^#$ ]]; then 
            break
        else
            pattern=$(python "$scripts"/parser.py "$line")
            sed -i "/$pattern/d" "$outputFile"
        fi
    done < "$smpout"/parsed_rfam_out.tblout

    # i don't understand why we need to concatenate the two, so here I'm going to only retain the predicted regions
    # cat $annotation "$smpout"/rfam_filtered_transcripts.txt > "$smpout"/final_combined.gtf

    mv "$smpout"/rfam_filtered_transcripts.txt "$smpout"/"${smpname}".lnc.gtf

    echo "done"
    echo ""

    ################################

    echo "processing identified lncRNA into GTF..."
    Rscript "$scripts"/lnc_processing.R \
        "$smpout"/"${smpname}".lnc.gtf \
        "$smpout"

    cp "$smpout"/"${smpname}".lnc.gtf "$lncout"

    echo "done"
    echo ""
}

# called upon completion of lncCall, performs abundance analysis for each BAM dependning on lnc arm
featureCountBranch () {
    echo "[$(date '+%d/%m/%Y %H:%M:%S')$smpkey] quantifying regular transcript abundance using featurecounts..."
    if [ ! -d "$out/featurecount_out" ]; then mkdir "$out/featurecount_out"; fi

    if [[ "$run_lnc" = true ]]; then
        # if lncRNA annotated we also feature count with the combined gtf, separate by PE det
        echo "[$smpkey] quantifying transcripts found in reads..."
        if [ "$det" -eq 1 ]; then
            echo "[$smpkey] running featurecount with $fclib as the -s argument"
            featureCounts \
                -T 2 \
                -t transcript \
                -s $fclib \
                -g $attribute_fc \
                -a "$out"/final_combined.gtf \
                -o "$smpout"/"$smpname"_transcript_abundance_lncRNA-included.txt \
                "$smpout"/sort_accepted.bam
        else
            featureCounts \
                -T 2 \
                -t transcript \
                -g $attribute_fc \
                -a "$out"/final_combined.gtf \
                -o "$smpout"/"$smpname"_transcript_abundance_lncRNA-included.txt \
                "$smpout"/sort_accepted.bam
        fi
        echo "[$smpkey] finished quantifying read features"
    fi
    # always do feature count with the regular gtf
    # first create gtf file from gff3 file
    gffread \
        "$annotation" \
        -T \
        -o "$out"/temp.gtf
    
    echo "[$smpkey] quantifying exons found in reads..."
    if [ "$det" -eq 1 ]; then
        echo "[$smpkey] running featurecount with $fclib as the -s argument"
        featureCounts \
            -T 2 \
            -t exon \
            -g $attribute_fc \
            -s $fclib \
            -a "$out"/temp.gtf \
            -o "$smpout"/"$smpname"_exon_abundance.txt \
            "$smpout"/sort_accepted.bam
    else
        featureCounts \
            -T 2 \
            -t exon \
            -g $attribute_fc \
            -a "$out"/temp.gtf \
            -o "$smpout"/"$smpname"_exon_abundance.txt \
            "$smpout"/sort_accepted.bam
    fi
    echo "[$smpkey] finished quantifying read features"

    # housekeeping for regular abundance
    cd "$smpout"
    mv *_featurecount.txt* "$out/featurecount_out"
    cd
}

# the wrapper around hamrBranch and lncCallBranch, is called once for each rep (or input file)
fastq2raw () {
    # translates string library prep strandedness into feature count required number
    # if [[ "$hisatlib" = R ]]; then
    #     fclib=2
    # elif [[ "$hisatlib" = F ]]; then
    #     fclib=1
    # elif [[ "$hisatlib" = RF ]]; then
    #     fclib=2
    # elif [[ "$hisatlib" = FR ]]; then
    #     fclib=1
    # else 
    #     fclib=0
    # fi

    # Read the CSV file into a DataFrame
    mapfile -t names < <(awk -F, '{ print $1 }' "$csv")
    mapfile -t smpf < <(awk -F, '{ print $2 }' "$csv")

    # Create a dictionary from the DataFrame
    declare -A dictionary
    for ((i=0; i<${#names[@]}; i++)); 
    do
        dictionary[${names[i]}]=${smpf[i]}
    done

    if [[ $smpkey == *_trimmed* ]]; then
        smpkey="${smpkey%_trimmed*}"
    fi

    # Retrieve the translated value
    if [[ ${dictionary[$smpkey]+_} ]]; then
        smpname="${dictionary[$smpkey]}"
        smpname="${smpname//$'\r'}"
        echo "[$smpkey] Sample group name found: $smpname"
    else
        echo "[$smpkey] Could not locate sample group name, exiting..."
        exit 1
    fi

    # Reassign / declare pipeline file directory
    if [ ! -d "$out/pipeline/$smpkey""_temp" ]; then
        mkdir "$out/pipeline/$smpkey""_temp"
        echo "[$smpkey] created path: $out/pipeline/$smpkey""_temp"
    fi

    smpout=$out/pipeline/$smpkey"_temp"
    echo "[$smpkey] You can find all the intermediate files for $smpkey at $smpout" 


    # Reassign hamr output directory
    if [ ! -d "$out/hamr_out" ]; then
        mkdir "$out"/hamr_out
        echo "created path: $out/hamr_out"
    fi

    # Reassign lnc output directory
    if [ ! -d "$out/lnc_out" ]; then
        mkdir "$out"/lnc_out
        echo "created path: $out/lnc_out"
    fi

    hamrout=$out/hamr_out
    lncout=$out/lnc_out

    echo "[$smpkey] You can find the HAMR output file for $smpkey at $hamrout/$smpname.mod.txt"
    echo "[$smpkey] You can find the lncRNA output file for $smpkey at $lncout/$smpname.mod.txt" 

    # check if progress.txt exists, if not, create it with 0
    if [[ ! -e "$smpout"/progress.txt ]]; then
        echo "0" > "$smpout"/progress.txt
    fi

    # determine stage of progress for this sample folder at this run
    # progress must be none empty so currProg is never empty
    currProg=$(cat "$smpout"/progress.txt)
    echo "----------------------------------------------------------"
    echo "Folder $smpkey is at progress number $currProg for this run"
    echo "----------------------------------------------------------"

    echo "$(date '+%d/%m/%Y %H:%M:%S') [$smpkey] Begin preprocessing pipeline"

    # if 0, then either this run failed before mapping completion or this run just started
    if [[ $currProg == "0" ]]; then
        cd "$smpout" || exit
        # maps the trimmed reads to provided annotated genome, can take ~1.5hr
        echo "--------Entering mapping step--------"
        if [[ "$hisat" = false ]]; then  
            echo "Using STAR for mapping..."
            if [ "$det" -eq 1 ]; then
                echo "[$smpkey] Performing STAR with a single-end file."
                STAR \
                --runThreadN 2 \
                --genomeDir "$out"/STARref \
                --readFilesIn "$smp" \
                --sjdbOverhang $overhang \
                --sjdbGTFfile "$annotation" \
                --sjdbGTFtagExonParentTranscript Parent \
                --outFilterMultimapNmax 10 \
                --outFilterMismatchNmax $mismatch \
                --outSAMtype BAM SortedByCoordinate
            else
                echo "[$smpkey] Performing STAR with a paired-end file."
                STAR \
                --runThreadN 2 \
                --genomeDir "$out"/STARref \
                --readFilesIn "$smp1" "$smp2" \
                --sjdbOverhang $overhang \
                --sjdbGTFfile "$annotation" \
                --sjdbGTFtagExonParentTranscript Parent \
                --outFilterMultimapNmax 10 \
                --outFilterMismatchNmax $mismatch \
                --outSAMtype BAM SortedByCoordinate
            fi

        else
            echo "Using HISAT2 for mapping..."
            # set read distabce based on mistmatch num
            red=8
            if [[ $mismatch -gt 8 ]]; then red=$((mismatch +1)); fi

            if [ "$det" -eq 1 ]; then
                echo "[$smpkey] Performing HISAT2 with a single-end file."
                hisat2 \
                    --rna-strandness "$hisatlib" \
                    --mp $mismatch,$mismatch \
                    --rdg $red,$red \
                    --rfg $red,$red \
                    --no-discordant \
                    --no-mixed \
                    -k 10 \
                    --very-sensitive \
                    --no-temp-splicesite \
                    --no-spliced-alignment \
                    -x "$out"/hsref/genome \
                    -U "$smp" \
                    -p 2 \
                    --dta-cufflinks \
                    -S output.sam \
                    --summary-file hisat2_summary.txt
            else
            echo "[$smpkey] Performing HISAT2 with a paired-end file."
                hisat2 \
                    --rna-strandness "$hisatlib" \
                    --mp $mismatch,$mismatch \
                    --rdg $red,$red \
                    --rfg $red,$red \
                    --no-discordant \
                    --no-mixed \
                    -k 10 \
                    --very-sensitive \
                    --no-temp-splicesite \
                    --no-spliced-alignment \
                    -x "$out"/hsref/genome \
                    -1 "$smp" \
                    -2 "$smp2" \
                    -p 2 \
                    --dta-cufflinks \
                    -S output.sam \
                    --summary-file hisat2_summary.txt
            fi
        fi
        cd || exit

        # mapping completed without erroring out if this is reached
        echo "1" > "$smpout"/progress.txt

        # update directly for normal progression
        currProg="1"
    fi

    wait

    # if 1, then either last run failed before sorting completion or this run just came out of mapping
    if [[ $currProg == "1" ]]; then
        #sorts the accepted hits
        echo "[$smpkey] sorting..."
        # handles HISAT or star output
        if [[ "$hisat" = false ]]; then
            samtools sort \
            -n "$smpout"/Aligned.sortedByCoord.out.bam \
            -o "$smpout"/sort_accepted.bam
        else
            samtools view -bS "$smpout"/output.sam > "$smpout"/output.bam
            samtools sort \
            -n "$smpout"/output.bam \
            -o "$smpout"/sort_accepted.bam
        fi
        echo "[$smpkey] finished sorting"
        echo ""

        # sorting completed without erroring out if this is reached
        echo "2" > "$smpout"/progress.txt
        currProg="2"
    fi

    wait

    # if both lnc and mod are true, then run them parallelized
    if [[ "$run_lnc" = true ]] && [[ "$run_mod" = true ]]; then
        hamrBranch &
        lncCallBranch
    # this means only lnc runs, mod doesn't
    elif [[ "$run_lnc" = true ]]; then
        lncCallBranch
    # this means only mod runs, lnc doesn't
    elif [[ "$run_mod" = true ]]; then
        hamrBranch
    fi

    wait

    if [[ "$run_featurecount" = true ]]; then
        featureCountBranch
    fi    

    wait

    # intermediate file clean up
    if [[ $currProg == "8" ]]; then
        # Move the unique_RG_ordered.bam and unique_RG_ordered.bai to a folder for read depth analysis
        cp "$smpout"/unique_RG_ordered.bam "$out"/pipeline/depth/"$smpname".bam
        cp "$smpout"/unique_RG_ordered.bai "$out"/pipeline/depth/"$smpname".bai

        # delete more intermediate files
        echo "[$smpkey] removing large intermediate files..."
        rm "$smpout"/sort_accepted.bam
        rm "$smpout"/unique.bam
        rm "$smpout"/unique_RG.bam
        rm "$smpout"/unique_RG_ordered.bam
        rm "$smpout"/unique_RG_ordered_splitN.bam
        rm "$smpout"/unique_RG_ordered_splitN.resort.bam
        echo "[$smpkey] finished cleaning"
        
        echo "9" > "$smpout"/progress.txt
    fi
}

# the wrapper around fastq2raw, iterates through existing files so fastq2raw can be called once for each file
parallelWrap () {
    smpext=$(basename "$smp")
    smpdir=$(dirname "$smp")
    smpkey="${smpext%.*}"
    smpname=""
    original_ext="${smpext##*.}"
    # always run the below to ensure necessary variables are assigned
    if [[ $smpkey == *_1* ]]; then
        smpkey="${smpkey%_1*}"
        smp1="$smpdir/${smpkey}_1_trimmed.$original_ext"
        smp2="$smpdir/${smpkey}_2_trimmed.$original_ext"
        # Paired end recognized
        det=0
        # in case user used single end for paired end
        # if [[ $hisatlib == R ]]; then
        #     hisatlib=RF
        # elif [[ $hisatlib == F ]]; then
        #     hisatlib=FR
        # fi
        echo "$smpext is a part of a paired-end sequencing file"
        echo ""
        fastq2raw
    elif [[ $smpkey == *_2* ]]; then
        # If _2 is in the filename, this file was processed along with its corresponding _1 so we skip
        echo "$smpext has already been processed with its _1 counter part. Skipped."
        echo ""
    else
        det=1
        echo "$smpext is a single-end sequencing file"
        echo ""
        fastq2raw
    fi
}

# de novo function to deal with consensus modifications
consensusOverlap () {
    IFS="/" read -ra sections <<< "$smp"
    temp="${sections[-1]}"

    IFS="." read -ra templ <<< "$temp"
    smpname="${templ[0]}"

    echo "consensus file prefix: $smpname"
    echo ""

    count=$(ls -1 "$out"/annotBeds/*_CDS.bed 2>/dev/null | wc -l)
    if [ "$count" != 0 ]; then 
        cds=$(find "$out"/annotBeds -maxdepth 1 -name "*_CDS.bed")
        #overlap with cds
        intersectBed \
            -a "$cds" \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname""_CDS".bed
        echo "finished finding overlap with CDS library"
    fi

    count=$(ls -1 "$out"/annotBeds/*_fiveUTR.bed 2>/dev/null | wc -l)
    if [ "$count" != 0 ]; then 
        fiveutr=$(find "$out"/annotBeds -maxdepth 1 -name "*_fiveUTR.bed")
        #overlap with 5utr
        intersectBed \
            -a "$fiveutr" \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname""_fiveUTR".bed
        echo "finished finding overlap with 5UTR library"
    fi

    count=$(ls -1 "$out"/annotBeds/*_threeUTR.bed 2>/dev/null | wc -l)
    if [ "$count" != 0  ]; then 
        threeutr=$(find "$out"/annotBeds -maxdepth 1 -name "*_threeUTR.bed")
        #overlap with 3utr
        intersectBed \
            -a "$threeutr" \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname""_threeUTR".bed
        echo "finished finding overlap with 3UTR library"
    fi

    count=$(ls -1 "$out"/annotBeds/*_gene.bed 2>/dev/null | wc -l)
    if [ "$count" != 0 ]; then 
        gene=$(find "$out"/annotBeds -maxdepth 1 -name "*_gene.bed")
        #overlap with gene
        intersectBed \
            -a "$gene" \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname""_gene".bed
        echo "finished finding overlap with gene library"
    fi

    count=$(ls -1 "$out"/annotBeds/*_primarymRNA.bed 2>/dev/null | wc -l)
    if [ "$count" != 0 ]; then 
        mrna=$(find "$out"/annotBeds -maxdepth 1 -name "*_primarymRNA.bed")
        #overlap with mrna
        intersectBed \
            -a "$mrna" \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname""_primarymRNA".bed
        echo "finished finding overlap with primary mRNA library"
    fi

    count=$(ls -1 "$out"/annotBeds/*_exon.bed 2>/dev/null | wc -l)
    if [ "$count" != 0 ]; then 
        exon=$(find "$out"/annotBeds -maxdepth 1 -name "*_exon.bed")
        #overlap with exon
        intersectBed \
            -a "$exon" \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname""_exon".bed
        echo "finished finding overlap with exon library"
    fi

    count=$(ls -1 "$out"/annotBeds/*_ncRNA.bed 2>/dev/null | wc -l)
    if [ "$count" != 0 ]; then 
        nc=$(find "$out"/annotBeds -maxdepth 1 -name "*_ncRNA.bed")
        #overlap with nc rna
        intersectBed \
            -a "$nc" \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname""_ncRNA".bed
        echo "finished finding overlap with ncRNA library"
    fi

    ######## this is from the lncRNA identification steps ##########
    # given lines of lncRNA region in gtf, see if any mod can be found there
    if [[ "$run_lnc" = true ]]; then
        intersectBed \
            -a "$smpout"/"$smpname".lnc.gtf \
            -b "$smp" \
            -wa -wb \
            > "$out"/lap/"$smpname"_overlapped_lnc.bed
        echo "finished finding overlap with lncRNA predictions"
    fi
}

# house keeping steps for fastqGrab functions, mostly creating folders and checking function calls
fastqGrabHouseKeeping () {
    ##########fastqGrab housekeeping begins#########
    if [ ! -d "$out" ]; then mkdir "$out"; echo "created path: $out"; fi

    if [ ! -d "$out/datasets" ]; then mkdir "$out"/datasets; echo "created path: $out/datasets"; fi

    # first see whether input folder is provided
    if [[ ! -z $fastq_in ]]; then
        fastq_in="$user_dir"/"$fastq_in"
        echo "Directory $fastq_in is found, assuming raw fastq files are provided..."
        mode=2
    else
        # Create directory to store original fastq files
        if [ ! -d "$out/datasets/raw" ]; then mkdir "$out"/datasets/raw; fi
        echo "You can find your original fastq files at $out/datasets/raw" 
        mode=1
        # grab txt from csv
        awk -F "," '{print $1}' $csv > "$user_dir"/accession.txt
        acc="$user_dir"/accession.txt
    fi

    if [ ! -d "$out/filein" ]; then 
        mkdir "$out/filein"
        echo "created path: $out/filein"
        # keeps a reference for the user inputted required files
        cp $genome "$out/filein"
        cp $annotation "$out/filein"
        cp $csv "$out/filein"
    fi

    # Create directory to store trimmed fastq files
    if [ ! -d "$out/datasets/trimmed" ]; then mkdir "$out"/datasets/trimmed; fi
    echo "You can find your trimmed fastq files at $out/datasets/trimmed"

    # Create directory to store fastqc results
    if [ ! -d "$out/datasets/fastqc_results" ]; then mkdir "$out"/datasets/fastqc_results; fi
    echo "You can find all the fastqc test results at $out/datasets/fastqc_results"

    # Run a series of command checks to ensure the entire script can run smoothly
    if ! command -v fasterq-dump > /dev/null; then
        echo "Failed to call fasterq-dump command. Please check your installation."
        exit 1
    fi

    if ! command -v fastqc > /dev/null; then
        echo "Failed to call fastqc command. Please check your installation."
        exit 1
    fi

    if ! command -v trim_galore > /dev/null; then
        echo "Failed to call trim_galore command. Please check your installation."
        exit 1
    fi

    if ! command -v gatk > /dev/null; then
        echo "Failed to call gatk command. Please check your installation."
        exit 1
    fi
    ##########fastqGrab housekeeping ends#########
}

# house keeping steps for fastq2raw, mostly creating folders, some indices, and checking function calls
fastq2rawHouseKeeping () {
    ############fastq2raw housekeeping begins##############
    # Checks if the files were trimmed or cleaned, and if so, take those files for downstream
    hamrin=""
    suf=""
    # If trimmed folder present, then user specified trimming, we take trimmed files with .fq
    if [ -d "$dumpout/trimmed" ]; then 
        hamrin=$dumpout/trimmed
        suf="fq"
    else
        echo "failed to locate trimmed fastq files"
        exit 1
    fi

    # Creating some folders
    if [ ! -d "$out/pipeline" ]; then mkdir "$out"/pipeline; echo "created path: $out/pipeline"; fi

    if [ ! -d "$out/hamr_out" ]; then mkdir "$out"/hamr_out; echo "created path: $out/hamr_out"; fi

    # Check if zero_mod is present already, if not then create one
    if [ ! -e "$out/hamr_out/zero_mod.txt" ]; then
        cd "$out/hamr_out" || exit
        echo "Below samples have 0 HAMR predicted mods:" > zero_mod.txt
        cd || exit
    fi


    # create dict file using fasta genome file
    count=$(ls -1 "$genomedir"/*.dict 2>/dev/null | wc -l)
    if [ "$count" == 0 ]; then 
    gatk CreateSequenceDictionary \
        R="$genome"
    fi
    dict=$(find "$genomedir" -maxdepth 1 -name "*.dict")

    # create fai index file using fasta genome
    count=$(ls -1 "$genomedir"/*.fai 2>/dev/null | wc -l)
    if [ "$count" == 0 ]; then 
    samtools faidx "$genome"
    fi

    # Check which mapping software, and check for index
    if [[ "$hisat" = false ]]; then  
    # Check if indexed files already present for STAR
        if [ -e "$out/STARref/SAindex" ]; then
            echo "STAR Genome Directory with indexed genome detected, skipping STAR indexing"
        else
            # get genome length
            genomelength=$(bioawk -c fastx '{ print length($seq) }' < $genome | awk '{sum += $1} END {print sum}')
            echo "For reference, your provided genome length is $genomelength long"

            # Define the SA index number argument
            log_result=$(echo "scale=2; l($genomelength)/l(2)/2 - 1" | bc -l)
            sain=$(echo "scale=0; if ($log_result < 14) $log_result else 14" | bc)
            echo "Creating STAR genome index..."
            # Create genome index 
            STAR \
                --runThreadN $threads \
                --runMode genomeGenerate \
                --genomeDir "$out"/STARref \
                --genomeFastaFiles "$genome" \
                --sjdbGTFfile "$annotation" \
                --sjdbGTFtagExonParentTranscript Parent \
                --sjdbOverhang $overhang \
                --genomeSAindexNbases $sain
        fi
    else
        # check for user input
        if [[ ! $hsref = "" ]]; then
            echo "user input for hisat index detected, skipping bowtie index generation"
        # Check if bowtie index directory is already present
        elif [ -e "$out/hsref" ]; then
            echo "existing bowtie indexed directory detected, skipping bowtie index generation"
        else
        # If not, first check if ref folder is present, if not then make
            if [ ! -d "$out/hsref" ]; then mkdir "$out/hsref"; echo "created path: $out/hsref"; fi
            cd $out/hsref
            echo "Creating hisat index..."
            hisat2-build -p 16 "$genome" genome
            cd 
        fi
    fi

    # Run a series of command checks to ensure fastq2raw can run smoothly
    if ! command -v mapfile > /dev/null; then
        echo "Failed to call mapfile command. Please check your installation."
        exit 1
    fi

    if ! command -v STAR > /dev/null; then
        echo "Failed to call STAR command. Please check your installation."
        exit 1
    fi

    if ! command -v samtools > /dev/null; then
        echo "Failed to call samtools command. Please check your installation."
        exit 1
    fi

    if ! command -v stringtie > /dev/null; then
        echo "Failed to call stringtie command. Please check your installation."
        exit 1
    fi

    if ! command -v cuffcompare > /dev/null; then
        echo "Failed to call cuffcompare command. Please check your installation."
        exit 1
    fi

    if ! command -v featureCounts > /dev/null; then
        echo "Failed to call featureCounts command. Please check your installation."
        exit 1
    fi

    if ! command -v gatk > /dev/null; then
        echo "Failed to call gatk command. Please check your installation."
        exit 1
    fi

    if ! command -v python > /dev/null; then
        echo "Failed to call python command. Please check your installation."
        exit 1
    fi

    # Creates a folder for depth analysis
    if [ ! -d "$out/pipeline/depth" ]; then mkdir "$out"/pipeline/depth; echo "created path: $out/pipeline/depth"; fi
    #############fastq2raw housekeeping ends#############
}

# house keeping steps before starting the main program, checks key arguments, set checkpoints, etc
mainHouseKeeping () {
    # Check if the required arguments are provided
    if [ -z "$out" ]; then 
        echo "output directory not detected, exiting..."
        exit 1
    elif [ -z "$csv" ]; then
        echo "filename dictionary csv not detected, exiting..."
        exit 1
    elif [ -z "$genome" ]; then
        echo "model organism genmome fasta not detected, exiting..."
        exit 1
    elif [ -z "$annotation" ]; then
        echo "model organism genmome annotation gff3 not detected, exiting..."
        exit 1
    elif [ -z "$length" ]; then
        echo "read length not detected, exiting..."
        exit 1
    else
        echo "all required arguments provided, proceding..."
    fi

    # check that the user didn't suppress all three programs -- if so, there's no need to run anything
    if [[ "$run_lnc" = false ]] && [[ "$run_featurecount" = false ]] && [[ "$run_mod" = false ]]; then
        echo "User has not activated any functionalities. Exiting..."
        exit 0
    fi

    # check whether checkpoint.txt is present 
    if [ -e "$out"/checkpoint.txt ]; then
        last_checkpoint=$(cat "$out"/checkpoint.txt)
        echo "Resuming from checkpoint: $last_checkpoint"
    else
        last_checkpoint="start"
    fi
}


######################################################### Main Program #########################################
echo ""
echo "##################################### Begin HAMRLINC #################################"
echo ""

# perform house keeping steps
mainHouseKeeping

# run fastqGrab when checkpoint is at start
if [ "$last_checkpoint" = "start" ] || [ "$last_checkpoint" = "" ]; then
    fastqGrabHouseKeeping
    ##########fastqGrab main begins#########
    if [[ $mode -eq 1 ]]; then
        # Grabs the fastq files from acc list provided into the dir ~/datasets
        i=0
        while IFS= read -r line
        do ((i=i%threads)); ((i++==0)) && wait
        fastqGrabSRA &
        done < "$acc"

    elif [[ $mode -eq 2 ]]; then
        i=0
        for fq in "$fastq_in"/*; 
        do
            ((i=i%threads)); ((i++==0)) && wait
            fastqGrabLocal &
        done
    fi
    wait
    ##########fastqGrab main ends############
    echo ""
    echo "################ Finished downloading and processing all fastq files. Entering pipeline for HAMR analysis. ######################"
    date '+%d/%m/%Y %H:%M:%S'
    echo ""

    # obtained all processed fastq files, record down checkpoint
    last_checkpoint="checkpoint1"
    checkpoint $last_checkpoint
fi

# run fastq2raw if program is at checkpoint 1
if [ "$last_checkpoint" = "checkpoint1" ]; then 
    fastq2rawHouseKeeping
    #############fastq2raw main begins###############
    # Pipes each fastq down the hamr pipeline, and stores out put in ~/hamr_out
    # Note there's also a hamr_out in ~/pipeline/SRRNUMBER_temp/, but that one's for temp files
    
    #mkdir trimmed_temp && mv "$hamrin"/*."$suf" trimmed_temp && chmod -R 777 trimmed_temp
    #cd trimmed_temp
    #current_dir=$(pwd)
    #cd ..

    i=0
    for smp in "$hamrin"/*."$suf"; 
    do
        ((i=i%ttop)); ((i++==0)) && wait   
        parallelWrap &
    done

    wait

    # these checks apply only if mod arm was on
    if [[ "$run_mod" = true ]]; then
        # Check whether any hamr.mod.text is present, if not, halt the program here
        if [[ -z "$(ls -A "$out"/hamr_out)" ]]; then
            echo "No HAMR predicted mod found for any sequencing data in this project, please see log for verification"
            exit 1
        else
            #at least 1 mod file, move zero mod record outside so it doesn't get read as a modtbl next
            mv "$out"/hamr_out/zero_mod.txt "$out"
        fi
    fi

    echo ""
    echo "################ Finished the requested analysis for each fastq file. Now producing consensus files and depth analysis. ######################"
    echo "$(date '+%d/%m/%Y %H:%M:%S')"
    echo ""

    #############fastq2raw main ends###############

    # obtained all HAMR / lnc results, record down checkpoint
    last_checkpoint="checkpoint2"
    checkpoint $last_checkpoint
fi

# run consensus when checkpoint is at 2
if [ "$last_checkpoint" = "checkpoint2" ]; then 
    ##############consensus finding begins##############
    # Produce consensus bam files based on filename (per extracted from name.csv) and store in ~/consensus
    if [ ! -d "$out/hamr_consensus" ]; then mkdir "$out"/hamr_consensus; echo "created path: $out/hamr_consensus"; fi
    if [ ! -d "$out/lnc_consensus" ]; then mkdir "$out"/lnc_consensus; echo "created path: $out/lnc_consensus"; fi

    # Run a series of command checks to ensure findConsensus can run smoothly
    if ! command -v Rscript > /dev/null; then
        echo "Failed to call Rscript command. Please check your installation."
        exit 1
    fi

    echo "Producing consensus file across biological replicates..."
    # Find consensus accross all reps of a given sample group
    if [[ "$run_mod" = true ]]; then
        Rscript "$scripts"/findConsensus.R \
            "$out"/hamr_out \
            "$out"/hamr_consensus
    fi

    if [[ "$run_lnc" = true ]]; then
        Rscript "$scripts"/findConsensus_lnc.R \
            "$out"/lnc_out \
            "$out"/lnc_consensus
    fi

    wait
    echo "done"

    # The case where no consensus file is found, prevents *.bed from being created
    if [ -z "$(ls -A "$out"/hamr_consensus)" ]; then
    echo "No consensus mods found within any sequencing group. Please see check individual rep for analysis. "
    exit 1
    fi

    # Add depth columns with info from each rep alignment, mutate in place
    for f in "$out"/hamr_consensus/*.bed
    do
        t=$(basename "$f")
        d=$(dirname "$f")
        n=${t%.*}
        echo "starting depth analysis on $n"
        for ff in "$out"/pipeline/depth/*.bam
        do
            if echo "$ff" | grep -q "$n"
            then
                tt=$(basename "$ff")
                nn=${tt%.*}
                echo "[$n] extracting depth information from $nn"
                for i in $(seq 1 $(wc -l < "$f"))
                do
                    chr=$(sed "${i}q;d" "$f" | sed 's/\t/\n/g' | sed '1q;d')
                    pos=$(sed "${i}q;d" "$f" | sed 's/\t/\n/g' | sed '2q;d')
                    dph=$(samtools coverage \
                        -r "$chr":"$pos"-"$pos" \
                        "$ff" \
                        | awk 'NR==2' | awk -F'\t' '{print $7}')
                    awk -v "i=$i" 'NR==i {print $0"\t"var; next} 1' var="$dph" "$f" > "$d"/"${nn}"_new.bed && mv "$d"/"${nn}"_new.bed "$f" 
                done
                echo "[$n] finished $nn"
            fi
        done &
    done
    wait

    for f in "$out"/hamr_consensus/*.bed
    do
        if [ -s "$f" ]; then
        # The file is not-empty.
            t=$(basename "$f")
            n=${t%.*}
            echo "computing depth across reps for $n"
            Rscript "$scripts"/depthHelperAverage.R "$f"
        fi
    done

    wait

    #############consensus finding ends###############

    # obtained all consensus HAMR mods with depth, record down checkpoint
    last_checkpoint="checkpoint3"
    checkpoint $last_checkpoint
fi

# run overlap when checkpoint agrees
if [ "$last_checkpoint" = "checkpoint3" ]; then 
    ##############overlapping begins##############
    # Produce overlap bam files with the provided annotation library folder and store in ~/lap
    if [ ! -d "$out/lap" ]; then mkdir "$out"/lap; echo "created path: $out/lap"; fi

    # Run a series of command checks to ensure consensusOverlap can run smoothly
    if ! command -v intersectBed > /dev/null; then
        echo "Failed to call intersectBed command. Please check your installation."
        exit 1
    fi

    # annot bed target directory
    if [ ! -d "$out/annotBeds" ]; then mkdir "$out"/annotBeds; echo "created path: $out/annotBeds"; fi

    # checks if genomedir is populated with generated annotation files, if not, hamrbox can't run anymore, exit
    count=$(ls -1 "$out/annotBeds"/*.bed 2>/dev/null | wc -l)
    if [ "$count" == 0 ]; then 
        if [[ -e "$generator" ]]; then
            echo "generating annotations for overlap..."
            # 11/17 redirect annotation generate output to out/annotBeds, second arg added
            Rscript "$generator" "$annotation" "$out/annotBeds"
        else
            echo "#########NOTICE###########"
            echo "##########No annotation generator or annotation files found, please check your supplied arguments##########"
            echo "##########As a result, HAMRLINC will stop here. Please provide the above files in the next run############"
            exit 1
        fi
    else 
        echo "generated annotation detected, proceeding to overlapping"
    fi

    # Overlap with provided libraries for each sample group
    for smp in "$out"/hamr_consensus/*
    do 
        consensusOverlap
    done

    if [ -z "$(ls -A "$out"/lap)" ]; then
    echo "No overlapped mods found within any sequencing group. Please see check individual rep for analysis. "
    exit 1
    fi

    #############overlapping ends###############

    # obtained all overlapped HAMR mods, record down checkpoint
    last_checkpoint="checkpoint4"
    checkpoint $last_checkpoint
fi

# run R analysis when checkpoint agrees
if [ "$last_checkpoint" = "checkpoint4" ]; then 
    ##############R analysis begins##############
    echo ""
    echo "###############SMACK portion completed, entering EXTRACT################"
    date '+%d/%m/%Y %H:%M:%S'
    echo ""
    #######################################begins EXTRACT######################################
    if [ ! -d "$out/results" ]; then mkdir "$out"/results; echo "created path: $out/results"; fi
    dir="$out/results"

    echo "generating long modification table..."
    # collapse all overlapped data into longdf
    Rscript "$scripts"/concatenate4R.R \
        "$out"/lap \
        "$out/results"
    echo "done"
    echo ""

    # note mod_long.csv is now in dir/results, update

    echo "plotting modification abundance per sample group..."
    # overview of modification proportion
    Rscript "$scripts"/countPerGroup.R \
        "$dir"/mod_long.csv \
        "$out"/annotBeds \
        "$dir"
    echo "done"
    echo ""

    echo "plotting modification abundance per mod type..."
    # overview of modification proportion
    Rscript "$scripts"/countPerMod.R \
        "$dir"/mod_long.csv \
        "$out"/annotBeds \
        "$dir"
    echo "done"
    echo ""

    echo "performing modification cluster analysis..."
    # analyze hamr-mediated/true clustering across project
    Rscript "$scripts"/clusterAnalysis.R \
        "$dir"/mod_long.csv \
        "$dir"
    echo "done"
    echo ""

    # if [ ! -z "${4+x}" ]; then
    #     echo "known modification landscape provided, performing relative positional analysis to known mod..."
    #     # The csv (in modtbl format) of the known mod you want analyzed in distToKnownMod
    #     antcsv=$4
    #     # analyze hamr-mediated/true clustering across project
    #     Rscript $scripts/distToKnownMod.R \
    #         $dir/mod_long.csv \
    #         $antcsv
    #     echo "done"
    #     echo ""
    # else 
    #     echo "known modification file not detected, skipping relative positional analysis"
    #     echo ""
    # fi

    if [ ! -d "$dir/go" ]; then mkdir "$dir"/go; echo "created path: $dir/go"; fi

    if [ ! -d "$dir/go/genelists" ]; then mkdir "$dir"/go/genelists; echo "created path: $dir/go/genelists"; fi

    if [ ! -d "$dir/go/pantherout" ]; then mkdir "$dir"/go/pantherout; echo "created path: $dir/go/pantherout"; fi

    if [ -z "/pantherapi-pyclient" ]; then
        echo "panther installation not found, skipping go analysis"
    else    
        echo "generating genelist from mod table..."
        # produce gene lists for all GMUCT (for now) groups
        Rscript "$scripts"/produceGenelist.R \
            "$dir"/mod_long.csv \
            "$dir"/go/genelists

        echo "editing panther param file with user input..."
        # edit params/enrich.json with user's input
        cd $util
        if [[ ! -z $porg ]]; then
            mv panther_params.json temp.json
            jq --arg jq_in $porg -r '.organism |= $jq_in' temp.json > panther_params.json
            rm temp.json

            mv panther_params.json temp.json
            jq --arg jq_in $porg -r '.refOrganism |= $jq_in' temp.json > panther_params.json
            rm temp.json
        fi

        if [[ ! -z $pterm ]]; then
            mv panther_params.json temp.json
            jq --arg jq_in $pterm -r '.annotDataSet |= $jq_in' temp.json > panther_params.json
            rm temp.json
        fi

        if [[ ! -z $ptest ]]; then
            mv panther_params.json temp.json
            jq --arg jq_in $ptest -r '.enrichmentTestType |= $jq_in' temp.json > panther_params.json
            rm temp.json
        fi

        if [[ ! -z $pcorrect ]]; then
            mv panther_params.json temp.json
            jq --arg jq_in $pcorrect -r '.correction |= $jq_in' temp.json > panther_params.json
            rm temp.json
        fi
        cd

        # proceed if genelists directory is not empty
        if [ -n "$(ls "$dir"/go/genelists)" ]; then
            echo "sending each gene list to panther for overrepresentation analysis..."
            # Send each gene list into panther API and generate a overrepresentation result file in another folter
            for f in "$dir"/go/genelists/*.txt
            do
                n=$(basename "$f")
                echo "$n"
                python $execpthr \
                    --service enrich \
                    --params_file $json \
                    --seq_id_file "$f" \
                    > "$dir"/go/pantherout/"$n"
            done

            echo "producing heatmap..."
            # Run the R script that scavenges through a directory for result files and produce heatmap from it
            Rscript "$scripts"/panther2heatmap.R \
                "$dir"/go/pantherout \
                "$dir"
        fi
    fi
    echo "done"
    echo ""

    echo "classifying modified RNA subtype..."
    # looking at RNA subtype for mods
    Rscript "$scripts"/RNAtype.R \
        "$dir"/mod_long.csv
    echo "done"
    echo ""

    if [ -e "$out"/annotBeds/*_CDS.bed ] && [ -e "$out"/annotBeds/*_fiveUTR.bed ] && [ -e "$out"/annotBeds/*_threeUTR.bed ]; then
        c=$(find "$out"/annotBeds -type f -name "*_CDS.bed")
        f=$(find "$out"/annotBeds -type f -name "*_fiveUTR.bed")
        t=$(find "$out"/annotBeds -type f -name "*_threeUTR.bed")
        echo "mapping modification regional distribution landscape..."
        # improved region mapping
        Rscript "$scripts"/modRegionMapping.R \
            "$dir"/mod_long.csv \
            "$f" \
            "$c" \
            "$t"
        echo "done"
        echo ""
    fi

    echo ""
    echo "#################################### HAMRLINC has finished running #######################################"
    date '+%d/%m/%Y %H:%M:%S'
    echo ""
fi
