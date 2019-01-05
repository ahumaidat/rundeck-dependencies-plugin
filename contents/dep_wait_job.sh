#!/bin/bash
# -------------------------------------------------------------------------------------------
# script d'attente d'un autre job et permettant de simuler une dependance 
# requiers un token d'acc�s en lecture a Rundeck dans la variable RD_TOKEN de l'environnement de Rundeck
#
# aide integree
# -------------------------------------------------------------------------------------------
# 2017/07/09    AHZ creation


# variables externes
# RD_TOKEN=<Rundeck API token in user env>
# RD_JOB_SERVERURL=<generated by rundeck>
# DEPENDENCY_IGNORE=<optional, empty or "anything non blank" >
# RD_FLOW_DAILY_START=<optional or "hh:mm:ss" as global, can also be set as a cmd line arg>
# RD_FLOW_DAILY_END=<optional or "hh:mm:ss" as global, can also be set as a cmd line arg >
# RD_TMP_DIR=<optional or path to the Rundeck tmp dir>


# default values
TARGET_PROJECT_NAME=""
TARGET_GROUP_NAME=""
TARGET_JOB_NAME=""
TARGET_JOB_ID=""
TARGET_JOB_SKIPFILE=""
TARGET_JOB_EXPECTED_STATUS=success
TARGET_JOB_MANDATORY=1
TARGET_JOB_DEP_RESOLVED=0
TARGET_JOB_ISRUNNING=""
TARGET_JOB_LASTEXEC_DATA=""
TARGET_JOB_LASTEXEC_STATUS=""
TARGET_JOB_LASTEXEC_TIME_END=""

TARGET_WAIT_TIMEOUT=$(( 18 * 60 * 60 ))
TARGET_WAIT_FORCE_EXEC=0

STARTUP_DELAY_SEC=5
SLEEP_DURATION_SEC=60
TIME_CURRENT=$( date "+%s" )
TIME_FLOW_DAILY_START=-1        # heure de reference du plan => plage de j+0_15h00 � j+1_14h59
TIME_FLOW_DAILY_END=-1
REF_FLOW_DAILY_START="${RD_FLOW_DAILY_START:-15:00:00}"
REF_FLOW_DAILY_END="${RD_FLOW_DAILY_END:-14:59:59}"

REF_TMP_DIR=${RD_TMP_DIR:-/tmp/rundeck}

CURL_API_ROOT="${RD_JOB_SERVERURL%/}/api"
CURL_API_CMD="curl --silent --get --data-urlencode authtoken=${RD_TOKEN} ${CURL_API_ROOT}"

VAL_OK=";ok;success;succeeded;"
VAL_KO=";ko;error;failed;aborted;timedout;timeout"


# ----------------------------------------------------------------------------
# syntaxe d'utilisation
function usageSyntax() {
    echo -e "
syntaxe    : $(basename $0) -project '<nom projet rundeck>' -group '<groupe de jobs>' -job '<nom du job>' [-state <success | error>] [-force_launch] [-hardlink|-softlink] [-wait <temps d'attente en sec>] [-bypass] [-flow_daily_start hh:mm:ss] [-flow_daily_end hh:mm:ss]

 -state    : etat attendu du job cible, par defaut : success
 -force_launch : force le lancement une fois la limite de periode atteinte
 -hardlink : (defaut) active la dependance et attend que le job cible soit lance s'il est absent
 -softlink : active la dependance uniquement si le job cible est deja lance (en cours, ou termine ok/ko)
 -wait     : temps d'attente maximal du job cible, par defaut (sec) : $TARGET_WAIT_TIMEOUT
 -bypass   : desactive la verification et sort immediatement sans erreur.
 -flow_daily_start : indique l'heure de debut du plan, par defaut : $REF_FLOW_DAILY_START
 -flow_daily_end : indique l'heure de fin du plan, par defaut : $REF_FLOW_DAILY_END
 
Notes : 
 * $(basename $0) reste en attente jusqu'a expiration du delai ou jusqu'a la fin du plan tant que le job indique n'est pas dans l'etat attendu.
 * si softlink est present mais que le job cible n'a pas ete lance, il n'y aura pas d'attente
 * valeurs possibles pour -state : success error
 "
}

# ----------------------------------------------------------------------------
# affichage sur stderr
echoerr() { printf "%s\n" "$*" >&2; }

# find a job GID from his project, group and job names
rdJob_GetIdFromName() {    
    CURL_API_VERSION=17
    sData=$( ${CURL_API_CMD}/${CURL_API_VERSION}/project/${TARGET_PROJECT_NAME}/jobs --data-urlencode groupPathExact="$TARGET_GROUP_NAME" --data-urlencode jobExactFilter="$TARGET_JOB_NAME"  )
    if [ $? -ne 0 ] || ! echo "$sData"|grep -i -q "<jobs count="; then echoerr "Error: rdJob_GetIdFromName - bad API query"; echoerr "$sData"; exit 1; fi
    if echo "$sData"|grep -i -q "<jobs count='0'"; then echoerr "Error: rdJob_GetIdFromName - target job wasn't found"; exit 1; fi
    if ! echo "$sData"|grep -i -q "<jobs count='1'>"; then echoerr "Error: rdJob_GetIdFromName - more than a single job was returned "; exit 1; fi
        
    # uniquement pour obtenir un message d'etat
    echoerr "Notice: JOB '${TARGET_JOB_NAME}' found - extracting id ..."
        
    # format attendu : <job id='a4997c82-86b9-42fb-8bfd-ff57fad90202' href='http://...' ...>
    echo "$sData" | grep -oP -i "job id='\K.*?(?=')"
}

# la commande liste la totalit� des jobs en execution, sans filtrage possible
rdJob_IsRunning() {
    CURL_API_VERSION=14
    sData=$( ${CURL_API_CMD}/${CURL_API_VERSION}/project/${TARGET_PROJECT_NAME}/executions/running   )
    if [ $? -ne 0 ]; then echoerr "Error: rdJob_IsRunning - bad API query"; echoerr "$sData"; exit 1; fi
    
    # recherche de l'id du job cible
    sData=$( echo "$sData" | grep "$TARGET_JOB_ID" | head -1 )
    
    if [ -z "$sData" ]; then 
        echo 0 
    else 
        echo 1
    fi
}

rdJob_GetLastExecData() {
    CURL_API_VERSION=1
    sData=$( ${CURL_API_CMD}/${CURL_API_VERSION}/job/${TARGET_JOB_ID}/executions --data-urlencode max=1 )    
    if [ $? -ne 0 ]; then echoerr "Error: rdJob_GetLastExecData - bad API query"; echoerr "$sData"; exit 1; fi

    echo "$sData" | grep -v '^#'
    return 0    # grep renvoie rc=1 s'il n'y a pas de donnees
}

# structure : 
# rd-cli: 29 succeeded 2017-05-25T11:21:00+0200 2017-05-25T11:21:01+0200 http://<server>:<port>/project/<project name>/execution/show/9 job b8bae947-013a-4097-819f-86870b19662e <group>/<job name>
# api : ... <execution id='1116 ... status='succeeded' ...> ... <date-started unixtime='1512882600352'>2017-12-10T05:10:00Z</date-started> ... <date-ended unixtime='1512882604078'>2017-12-10T05:10:04Z</date-ended> ...
rdJob_GetLastExecValue() {
valueRet=""

    case $1 in
        -exec_id)
            valueRet=$( echo "$TARGET_JOB_LASTEXEC_DATA" | grep -oP -i "execution id='\K.*?(?=')" )
            ;;
        
        -exec_url)
            valueRet=$( echo "$TARGET_JOB_LASTEXEC_DATA" | grep -oP -i "<execution id=.* href='\K.*?(?=')" )
            ;;
        
        -time_start)
            valueRet=$( echo "$TARGET_JOB_LASTEXEC_DATA" | grep -oP -i "date-started unixtime='\K.*?(?=')" )
            if [ ! -z "$valueRet" ]; then
                #cli only: valueRet=$( date -d "$valueRet" "+%s" )
                valueRet=$(( $valueRet / 1000 ))    # api unix time is in ms
            else
                valueRet=-1
            fi
            ;;

        -time_end)
            valueRet=$( echo "$TARGET_JOB_LASTEXEC_DATA" | grep -oP -i "date-ended unixtime='\K.*?(?=')" )
            if [ ! -z "$valueRet" ]; then
                #cli only: valueRet=$( date -d "$valueRet" "+%s" )
                valueRet=$(( $valueRet / 1000 ))    # api unix time is in ms
            else
                valueRet=-1
            fi
            ;;
        
        -status|-state)
            valueRet=$( echo "$TARGET_JOB_LASTEXEC_DATA" | grep -oP -i "<execution id=.* status='\K.*?(?=')" )
            if [ -z "$valueRet" ]; then valueRet="unknown"; fi
            if echo "$VAL_OK"|grep -q "$valueRet"; then valueRet="success"; fi
            if echo "$VAL_KO"|grep -q "$valueRet"; then valueRet="error"; fi
            ;;
        
        *)
            echoerr "Error: rdJob_GetLastExecValue -  '$1' argument is unknown"
            exit 1
            ;;
        
    esac

    echo "$valueRet"
}
        
# ----------------------------------------------------------------------------
echo "RUNDECK DEPENDENCIES WAIT_JOB MODULE"
echo "Command line used : $0 $*"
echo ""

# test d'acces a l'API via curl
sTemp=$( ${CURL_API_CMD}/1/projects 2>&1)
if [ $? -ne 0 ] || ! echo "$sTemp" | grep -i -q "projects count="; then echoerr "Error: cannot contact rundeck through the API"; echoerr "$sTemp"; exit 1; fi


# verification de la presence de parametres
if [ $# -eq 0 ]; then usageSyntax; exit 1; fi

# traitement de la ligne de commande
while [ $# -gt 0 ]; do 
    arg="$1"

    case $arg in
        -project)
            TARGET_PROJECT_NAME=$( echo "$2" | sed 's/^ *//;s/ *$//' )
            shift
            ;;

        -group)
            TARGET_GROUP_NAME=$( echo "$2" | sed 's/^ *//;s/ *$//' )
            shift
            ;;

        -job)
            TARGET_JOB_NAME=$(echo "$2" | sed 's/^ *//;s/ *$//' )
            shift
            ;;
        
        -state)
            TARGET_JOB_EXPECTED_STATUS=$( echo "$2" | tr '[:upper:]' '[:lower:]' )
            if ! echo "$VAL_OK;$VAL_KO" | grep -q "$TARGET_JOB_EXPECTED_STATUS"; then echoerr "Error: unexpected value '$2' for -state"; exit 1; fi
            shift
            ;;

        -hardlink)
            TARGET_JOB_MANDATORY=1
            ;;
            
        -softlink)
            TARGET_JOB_MANDATORY=0
            ;;

        -force_launch)
            TARGET_WAIT_FORCE_EXEC=1
            ;;

        -wait|-max[wW]ait)
            TARGET_WAIT_TIMEOUT=$(echo "$2" | sed 's/^ *//;s/ *$//' )
            if ! [[ $TARGET_WAIT_TIMEOUT =~ '^[0-9]+$' ]] ; then echoerr "Error: $arg $2 must be a number"; exit 1; fi
            shift
            ;;

        -startup_delay)
            STARTUP_DELAY_SEC=$(echo "$2" | sed 's/^ *//;s/ *$//' )
            shift
            ;;
            
        -bypass)
            DEPENDENCY_IGNORE=1
            ;;
        
        -sleep_duration)
            SLEEP_DURATION_SEC=$(echo "$2" | sed 's/^ *//;s/ *$//' )
            shift
            ;;

        -flow_daily_start)
            REF_FLOW_DAILY_START=$(echo "$2" | sed 's/^ *//;s/ *$//' )
            shift
            ;;

        -flow_daily_end)
            REF_FLOW_DAILY_END=$(echo "$2" | sed 's/^ *//;s/ *$//' )
            shift
            ;;
            
        *)
            # rundeck can pass additionals spaces as args
            if [ ! -z "$( echo $1 | tr -d '[:space:]' )" ]; then
                echoerr "Error: '$1' argument is unknown"
                usageSyntax
                exit 1
            fi
            ;;
    esac
    
    #  argument suivant
    [ $# -gt 0 ] && shift
done

# verification valeurs recue
if [ -z "$TARGET_PROJECT_NAME" ]; then echoerr "Error: the job's project name is required"; exit 1; fi
if [ -z "$TARGET_GROUP_NAME" ]; then echoerr "Error: the job's group name is required"; exit 1; fi
if [ -z "$TARGET_JOB_NAME" ]; then echoerr "Error: the job name is required"; exit 1; fi


# calcul des limites horaires du plan
dTodayLimit=$( date "+%Y-%m-%d ${REF_FLOW_DAILY_START}" )
dTodayLimit=$( date -d "${dTodayLimit}" "+%s" )

# Le plan en cours se termine depuis j-1
if [ $TIME_CURRENT -lt $dTodayLimit ]; then
    TIME_FLOW_DAILY_START=$( date --date='-1 day' "+%Y-%m-%d ${REF_FLOW_DAILY_START}" )
    TIME_FLOW_DAILY_START=$( date -d "${TIME_FLOW_DAILY_START}" "+%s" )
    
    TIME_FLOW_DAILY_END=$( date "+%Y-%m-%d ${REF_FLOW_DAILY_END}" )
    TIME_FLOW_DAILY_END=$( date -d "${TIME_FLOW_DAILY_END}" "+%s" )

# le plan est celui qui commence jusqu'� j+1
else
    TIME_FLOW_DAILY_START=$( date "+%Y-%m-%d ${REF_FLOW_DAILY_START}" )
    TIME_FLOW_DAILY_START=$( date -d "${TIME_FLOW_DAILY_START}" "+%s" )
    
    TIME_FLOW_DAILY_END=$( date --date='+1 day' "+%Y-%m-%d ${REF_FLOW_DAILY_END}" )
    TIME_FLOW_DAILY_END=$( date -d "${TIME_FLOW_DAILY_END}" "+%s" )
fi

# information banner
echo "Current PID:$$"
echo "----------------------------------------------"
echo "FLOW START: $( date -d @$TIME_FLOW_DAILY_START --rfc-2822 )"
echo "FLOW END:   $( date -d @$TIME_FLOW_DAILY_END --rfc-2822 )"
echo "PROJECT:    $TARGET_PROJECT_NAME"
echo "JOB group:  $TARGET_GROUP_NAME"
echo "JOB name:   $TARGET_JOB_NAME"
echo "JOB wanted state : $TARGET_JOB_EXPECTED_STATUS"
echo "JOB dep type: $( if [ $TARGET_JOB_MANDATORY -eq 0 ]; then echo 'optional'; else echo 'required'; fi )"
echo "----------------------------------------------"
echo ""

# verification du respect de la dependance
if [ ! -z "$DEPENDENCY_IGNORE" ]; then
    echo "DEPENDENCY_IGNORE variable or -bypass parameter is set => the script will exit immediately => success"
    exit 0
fi

# temporisation
sleep ${STARTUP_DELAY_SEC}s

# recherche de l'id du job cible
TARGET_JOB_ID=$( rdJob_GetIdFromName ) || exit 1
TARGET_JOB_SKIPFILE=${REF_TMP_DIR}/deps_skip.$$.${TARGET_JOB_ID}

echo "JOB ID found: $TARGET_JOB_ID"
echo ""

echo "Waiting loop started ($TARGET_WAIT_TIMEOUT sec)..."
echo "Shell command to skip this loop : touch ${TARGET_JOB_SKIPFILE}"
echo ""
# traitement du job jusqu'a la fin du timeout
nCount=0
while [ $nCount -lt ${TARGET_WAIT_TIMEOUT} ]; do    
    
    # verification du fichier skip
    if [ ! -z "$TARGET_JOB_SKIPFILE" ] && [ -f "$TARGET_JOB_SKIPFILE" ]; then
        echo "Skip file $TARGET_JOB_SKIPFILE present => success"
        rm "$TARGET_JOB_SKIPFILE"   || exit 1
        TARGET_JOB_DEP_RESOLVED=1
        break
    fi
    
    # Etat d'execution du job
    TARGET_JOB_ISRUNNING=$( rdJob_IsRunning ) || exit 1
    
    if [ "$TARGET_JOB_ISRUNNING" == "0" ]; then
        # recuperation des donnees de la derniere execution, si disponibles
        TARGET_JOB_LASTEXEC_DATA=$( rdJob_GetLastExecData ) || exit 1
        if [ ! -z "$TARGET_JOB_LASTEXEC_DATA" ]; then
            TARGET_JOB_LASTEXEC_STATUS=$( rdJob_GetLastExecValue -status ) || exit 1
            RD_JOB_LASTEXEC_TIME_START=$( rdJob_GetLastExecValue -time_start ) || exit 1
            TARGET_JOB_LASTEXEC_TIME_END=$( rdJob_GetLastExecValue -time_end ) || exit 1
            
            # verif si la date de demarrage du job cible correspond au plan du jour
            if [ $RD_JOB_LASTEXEC_TIME_START -ge $TIME_FLOW_DAILY_START ]; then
            
                # le job correspond au plan en cours, verification de son etat
                # si l'etat du job n'est pas celui attendu => retour en attente
                case "$TARGET_JOB_EXPECTED_STATUS" in
                
                    success|ok)
                        if echo "$VAL_OK" | grep -q "$TARGET_JOB_LASTEXEC_STATUS"; then 
                            echo "Valid execution found : $( date --iso-8601=seconds -d @$TARGET_JOB_LASTEXEC_TIME_END ) => status: $TARGET_JOB_LASTEXEC_STATUS"
                            TARGET_JOB_DEP_RESOLVED=1
                            break
                        fi
                        ;;
                    
                    error|failed|ko)
                        if echo "$VAL_KO" | grep -q "$TARGET_JOB_LASTEXEC_STATUS"; then 
                            echo "Valid execution found : $( date --iso-8601=seconds -d @$TARGET_JOB_LASTEXEC_TIME_END ) => status: $TARGET_JOB_LASTEXEC_STATUS"
                            TARGET_JOB_DEP_RESOLVED=1
                            break
                        fi
                        ;;
                esac

            # plan du job trouve different
            else
                # verification du type de dependance
                if [ $TARGET_JOB_MANDATORY -eq 0 ]; then
                    echo "No job execution for the current flow AND optional dependency => success"
                    TARGET_JOB_DEP_RESOLVED=1
                    break
                fi
                
                # attente
            fi
            
        # no data
        else
            # dependance optionnelle => job absent
            if [ $TARGET_JOB_MANDATORY -eq 0 ]; then
                echo "No job execution data found AND optional dependency => success"
                TARGET_JOB_DEP_RESOLVED=1
                break
            fi
            
            # toujours pas de job => attente
        fi    
    fi
    
    nCount=$(( $nCount + $SLEEP_DURATION_SEC ))
    if [ $(( $nCount % 3600 )) -eq 0 ]; then echo "Still waiting after $(( $nCount / 3600 )) hour"; fi
    if [ $( date "+%s" ) -ge $TIME_FLOW_DAILY_END ]; then echo "Flow limit reached: $( date -d @${TIME_FLOW_DAILY_END} --iso-8601=seconds ) => timeout"; break; fi
    sleep ${SLEEP_DURATION_SEC}s
done

if [ $TARGET_JOB_DEP_RESOLVED -eq 0 ] && [ $TARGET_WAIT_FORCE_EXEC -eq 1 ]; then 
    echo "Timeout reached AND forced execution active => success"
    TARGET_JOB_DEP_RESOLVED=1
fi

if [ $TARGET_JOB_DEP_RESOLVED -eq 0 ]; then 
    echo "Timeout reached and no valid job found with status: $TARGET_JOB_EXPECTED_STATUS => aborted"
    exit 1
fi

exit 0
