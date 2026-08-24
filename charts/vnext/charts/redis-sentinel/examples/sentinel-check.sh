#!/usr/bin/env bash
# redis-sentinel: CLUSTER INFO / CLUSTER NODES / set / get karsiliklari.
#
#   ./sentinel-check.sh <namespace> <release>
#
# Cluster alistirmalarindan gelen iki tuzak burada YOK:
#   -c yok            cluster modu bayragi, burada anlami yok
#   READONLY yok      cluster-disi replika duz GET'e cevap verir
set -u
NS="${1:-test-devops}"
REL="${2:-}"
[ -n "$REL" ] || { echo "kullanim: $0 <namespace> <release>"; exit 2; }
R="${REL}-redis-sentinel"

SEN() { kubectl -n "$NS" exec "$1" -c sentinel -- sh -c \
  "redis-cli -p 26379 -a \$SENTINEL_PASSWORD --no-auth-warning $2" 2>/dev/null | tr -d '\r'; }
RED() { kubectl -n "$NS" exec "$1" -c redis -- sh -c \
  "redis-cli -a \$REDIS_PASSWORD --no-auth-warning $2" 2>/dev/null | tr -d '\r'; }

# Pod listesi kubectl'den: replicaCount 3 varsaymak, tam olarak degistirilebilir
# olan seyi varsaymak olur.
PODS=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=redis" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)
[ -n "$PODS" ] || { echo "HATA: '$REL' icin pod bulunamadi (component=redis etiketi 1.3.0'dan itibaren var)"; exit 1; }
P0=$(printf '%s\n' "$PODS" | head -1)

echo "═══ 1) Sentinel'in kendi gorusu  (CLUSTER INFO'nun ilk yarisi)"
M0=$(SEN "$P0" 'INFO sentinel' | grep '^master0')
echo "    $M0"
NPODS=$(printf '%s\n' "$PODS" | wc -l | tr -d ' ')
SL=$(printf '%s' "$M0" | sed -n 's/.*slaves=\([0-9]*\).*/\1/p')
SN=$(printf '%s' "$M0" | sed -n 's/.*sentinels=\([0-9]*\).*/\1/p')
printf '    pod sayisi=%s  ->  beklenen slaves=%s, sentinels=%s\n' "$NPODS" "$((NPODS-1))" "$NPODS"
if [ "$SL" != "$((NPODS-1))" ]; then
  echo "    !! slaves=$SL, beklenen $((NPODS-1)). Kayitlar pod'a esleniyor:"
  # Her kaydi bir pod'a coz: hostname -> ilk DNS etiketi, IP -> pod IP'siyle esle.
  # Ayni pod iki kez cikarsa nedeni ASAGIDA yaziyor - bu, s_down olan bayat bir
  # kayit DEGIL, ikisi de canli.
  IPMAP=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/instance=${REL},app.kubernetes.io/component=redis" \
            -o jsonpath="{range .items[*]}{.status.podIP} {.metadata.name}{'\n'}{end}")
  DUP=0
  SEEN=""
  for a in $(SEN "$P0" 'SENTINEL replicas mymaster' | grep -A1 '^ip$' | grep -vE '^(ip|--)$'); do
    case "$a" in
      *[!0-9.]*) pod="${a%%.*}"; form=hostname ;;
      *) pod=$(printf '%s\n' "$IPMAP" | awk -v ip="$a" '$1==ip {print $2}'); form=IP ;;
    esac
    pod="${pod:-<eslenemedi>}"
    printf '       %-6s %-48s -> %s\n' "$form" "$a" "$pod"
    case " $SEEN " in *" $pod "*) DUP=1 ;; esac
    SEEN="$SEEN $pod"
  done
  if [ "$DUP" = "1" ]; then
    echo "       ^^ Ayni pod iki kez: biri hostname, biri IP. Ilk failover'dan sonra"
    echo "          olusur - Sentinel monitor'u FQDN ile tohumlanir, replikalari ise"
    echo "          master'in INFO replication'indan IP olarak ogrenir. announce-hostnames"
    echo "          her iki formu ayri kayit olarak yasatiyor."
    echo "          Ne kadar yasadigi OLCULMEDI: iki kayit da ayni canli pod'a cozuluyor,"
    echo "          yani mekanizma 'hicbiri budanmaz' diyor - ama bu cikarim, gozlem degil."
    echo "          Kozmetik: failover secimi ayni pod'un iki kaydindan birini secerse"
    echo "          zarari yok. Rahatsiz ediyorsa her Sentinel'de: SENTINEL RESET mymaster."
    echo "          slaves= uzerine ALARM KURMAYIN - CKQUORUM ve role:master sayisi kesin."
  fi
fi
[ "$SN" != "$NPODS" ] && echo "    !! sentinels=$SN, beklenen $NPODS - bir Sentinel gorulmuyor"

echo
echo "═══ 2) CKQUORUM  (CLUSTER INFO'nun asil sordugu sey: su an failover olabilir mi)"
CK=$(SEN "$P0" 'SENTINEL CKQUORUM mymaster')
echo "    $CK"
case "$CK" in
  OK*) ;;
  *) echo "    !! failover ANLASILAMAZ. Bir ariza uzakta sikismis durumdasiniz." ;;
esac

echo
echo "═══ 3) Her pod'un rolu, ve master hangisi  (CLUSTER NODES karsiligi)"
# Master'i POD'LARA SORARAK buluyoruz, Sentinel'in verdigi adresi ayristirarak DEGIL.
#
# Bir onceki surum adresi ayristiriyordu ve NodePort duyurusu acildiginda kirildi:
# Sentinel artik nodeHost donduruyor (ornek 10.180.141.16), script bunu pod IP'si
# sanip eslestiremiyor ve "adres bir pod'a eslenemedi" ile cikiyordu. Adres formu
# uce cikti - pod FQDN, pod IP, nodeHost:nodePort veya LB IP - ve her birini
# ayristirmak, chart'in zaten bildigi seyi script'te tekrar etmek olur.
#
# role:master'i sormak bicimden bagimsiz ve zaten dogru cevap: rolu Redis biliyor.
MASTERS=0
MASTER_POD=""
for p in $PODS; do
  line=$(RED "$p" 'INFO replication' \
    | grep -E '^role|^master_link_status|^connected_slaves|^slave_repl_offset|^master_repl_offset' \
    | tr '\n' ' ')
  printf '    %-40s %s\n' "$p" "$line"
  case "$line" in
    *'role:master'*) MASTERS=$((MASTERS+1)); [ -z "$MASTER_POD" ] && MASTER_POD="$p" ;;
  esac
done
echo "    role:master sayisi = $MASTERS  ($([ "$MASTERS" = 1 ] && echo 'DOGRU' || echo 'HATA: tam 1 olmali - iki master = split brain'))"
[ -n "$MASTER_POD" ] || { echo "    !! HIC master yok - failover penceresinde olabilirsiniz, tekrar deneyin"; exit 1; }
echo "    master pod: $MASTER_POD"

echo
echo "═══ 4) Sentinel istemcilere hangi adresi veriyor"
ADDR=$(SEN "$P0" 'SENTINEL get-master-addr-by-name mymaster' | tr '\n' ' ')
echo "    $ADDR"
case "$ADDR" in
  ' '|'')
    echo "    !! BOS - Sentinel'ler bir master uzerinde ANLASMAMIS. Istemciler master'i"
    echo "       bulamaz. CKQUORUM yukarida OK dese bile bu bir arizadir." ;;
  *) # Adresin cluster-ICI olmasi gerekmiyor ve olmamasi da bir sorun degil:
     # externalAccess acikken kasten DIS adres olur, replication ise cluster-ici
     # FQDN kullanir. Ikisinin FARKLI olmasi dogru davranistir.
     #
     # Kontrol edilecek sey adresin master pod'a isaret etmesi:
     #   pod FQDN            ilk etiket = $MASTER_POD olmali
     #   nodeHost:<port>     port, $MASTER_POD'un nodePort'u olmali:
     #                       oc -n $NS get svc ${MASTER_POD}-external
     case "$ADDR" in
       "${MASTER_POD}."*) echo "    -> master pod'un cluster-ici FQDN'i, tutarli" ;;
       *) echo "    -> DIS adres. Master pod'un nodePort'uyla karsilastirin:"
          echo "       oc -n $NS get svc ${MASTER_POD}-external -o jsonpath='{.spec.ports[*].nodePort}'; echo" ;;
     esac ;;
esac

echo
# ONCE OKU, sonra yaz. Ters sirasi bir restart'tan sonra veri kaybini MASKELER:
# taze bir SET her zaman 234 dondurur ve kaybi gormezsiniz. Diskless sentinel'de
# handover basarisiz oldugunda tam olarak bu olur.
echo "═══ 5a) ONCEKI degeri oku (veri restart'tan sag cikti mi)"
PREV=$(RED "$MASTER_POD" 'get aydemir')
if [ -n "$PREV" ]; then
  echo "    master'da onceki deger DURUYOR: aydemir=$PREV"
else
  echo "    master'da onceki deger YOK."
  echo "    Ilk kurulumda normal. Ama bir master silme/restart'indan SONRA bu"
  echo "    veri kaybidir - diskless'te handover basarisiz oldugunda beklenen sonuc."
fi

echo
echo "═══ 5b) Master'a yaz, geri oku, sonra REPLIKADAN oku"
RED "$MASTER_POD" 'set aydemir 234' | sed 's/^/    master set  : /'
RED "$MASTER_POD" 'get aydemir'     | sed 's/^/    master get  : /'
for p in $PODS; do
  [ "$p" = "$MASTER_POD" ] && continue
  # Yavas link veri kaybi degil: 5 kez dene, sonra pes et.
  v=""; n=0
  while [ $n -lt 5 ]; do
    v=$(RED "$p" 'get aydemir')
    [ -n "$v" ] && break
    n=$((n+1)); sleep 1
  done
  printf '    replica %-32s aydemir=%s %s\n' "$p" "${v:-<bos>}" \
    "$([ "$v" = "234" ] && echo '(replication OK)' || echo '(!! 5s icinde gelmedi)')"
done

echo
echo "═══ 6) Negatif kontrol: replikaya yazmak REDDEDILMELI"
for p in $PODS; do
  [ "$p" = "$MASTER_POD" ] && continue
  printf '    %-40s ' "$p"
  RED "$p" 'set nope 1' 2>&1 | head -1
  break
done
