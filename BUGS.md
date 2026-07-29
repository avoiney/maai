# myterm — bugs et réserves connus

Relevé issu d'une relecture complète (~5 300 lignes) le 2026-07-29, à l'état
`5b49fd9` + arbre de travail. Suite de tests : 62/62 OK — aucun des points
ci-dessous n'est couvert par un test existant.

Ordre de traitement recommandé : 1, 2, puis la mesure du coût de resize (§R1)
avant d'écrire de nouvelles fonctionnalités. Les points 3 à 5 peuvent attendre la
phase 3.

## État au 2026-07-29 (après `41f24ec`)

| Point | État |
|---|---|
| §1 cluster perdu au resize | **corrigé** — `grapheme` testé avant les prédicats de blanc, dans `grid.zig`, `cell.zig` et `selection.zig` ; test de non-régression ajouté |
| §2 table de styles non recyclée | **corrigé** — marquage-compactage dans `Screen.collectGarbage`, avec temporisation quand l'ensemble vivant est réellement grand |
| §3 `GraphemeTable` sans borne | **corrigé** — même passage de ramassage ; le contrôle vit aussi dans `extendCluster`, la croissance étant pilotée par `print` et non par SGR |
| §4 spin CPU si le compositeur meurt | **corrigé** — sortie sur `POLLERR/HUP/NVAL`, et `dispatch_pending < 0` traité comme fatal |
| §5 UTF-8 overlongs et surrogates | **corrigé** — validation du codepoint assemblé, U+FFFD sinon ; tests des bornes de chaque longueur |
| §R1 coût du reflow | **mesuré, partiellement corrigé** — voir le tableau de chiffres plus bas |
| §R2 taille de `screen.zig` | **ouvert** |
| §D1 commentaires périmés | **corrigé** pour l'en-tête de `screen.zig` (double largeur) ; les deux TODO de `cell.zig` restent exacts tant que §2 et §3 sont ouverts |

## Mesures (`zig build bench -Doptimize=ReleaseFast`)

Harnais dans `src/bench.zig` : aucune dépendance Wayland/EGL/fcft, donc un chiffre
s'attribue à une couche et non à « le terminal ». Minimum de 5 exécutions après un
tour de chauffe écarté, écart au-dessus indiqué, horloge monotone, allocations
comptées par un allocateur enveloppant.

| Cas | Avant | Après |
|---|---|---|
| truecolor SGR par cellule (2 MiB) | 239 909 ms | **10,1 ms** — 198 MiB/s |
| 150k styles distincts | 102 703 ms | **13,9 ms** |
| reflow, 10k lignes, largeur −1 | 11,4 ms · 19,2 MiB | inchangé |
| reflow, 10k lignes, hauteur −1 | 11,1 ms · 19,2 MiB | **0,009 ms · 0,1 MiB** |
| parse ASCII (4 MiB) | — | 26,8 ms — 149 MiB/s |
| parse CJK + combinantes (2 MiB) | — | 8,7 ms — 231 MiB/s |
| 50k défilements de ligne | — | 2,7 ms |

Deux enseignements de la mesure :

1. **Mon propre ramassage était quadratique.** Avec du truecolor par cellule chaque
   style est référencé par une cellule vivante : le balayage ne libère rien, réarme
   au plafond, et repart à chaque SGR pour rebalayer 2,4 M de cellules. 240 secondes
   pour 2 MiB. Corrigé par une temporisation : un ramassage improductif désarme le
   suivant pour 65536 internements et on accepte la saturation — ce qui est honnête,
   on ne peut pas représenter plus de 65535 styles simultanés.
2. **Le redimensionnement purement vertical ne nécessite aucun re-wrap.** Chaque
   ligne garde sa largeur et ses drapeaux ; `rows` n'est que « combien du ring est
   visible ». Voie rapide en O(rows) : 1200× plus rapide, et 190× moins d'allocation.

Reste ouvert : le changement de **largeur** coûte toujours 11,4 ms et 19,2 MiB. À
75 Hz pendant un glisser de bord latéral, c'est 0,85 s de travail par seconde — le
budget de trame de 13 ms est dépassé. Pistes non tentées : ne pas `memset` le slab
que l'on va réécrire ; ne reflower que l'historique réellement atteignable et
différer le reste. À mesurer de nouveau avant de choisir.

Bug supplémentaire trouvé hors relevé, signalé à l'usage : **coller dans myterm ce
qu'on venait d'y copier ne faisait rien.** Interblocage sur soi-même — on demandait
la sélection au compositeur, qui nous la redemandait par un événement `send` alors
qu'on était déjà bloqué en `poll` sur le tube, sans dépiler les événements. Le
collage n'aboutissait qu'à l'expiration du délai, donc vide. On répond désormais
depuis notre propre tampon quand on possède la sélection ; on ne peut pas dépiler
pendant l'attente, `paste` étant appelé depuis un listener, donc à l'intérieur de
`wl_display_dispatch_pending`, et libwayland interdit le dispatch réentrant.

---

## 1. Le premier cluster de graphèmes de la session disparaît au resize

**Sévérité : haute — perte de données silencieuse.**
**Fichiers :** `src/term/grid.zig:41-43`, `src/term/cell.zig:70-72`

`GraphemeTable.add` renvoie un index stocké dans `Cell.content`. Le premier
cluster de la session reçoit l'index 0, soit exactement `Cell.empty`. Or
`trimmable()` teste :

```zig
return (c.content == Cell.empty or c.content == ' ') and c.style == 0;
```

…**sans regarder `c.grapheme`**. Le cluster d'index 0 et celui d'index 32
(`' '`) sont donc pris pour des blancs et rognés en fin de ligne logique par le
reflow. `Cell.isBlank()` a le même défaut.

Reproduction (vérifiée par test jetable) :

```
état initial : content=0 grapheme=true
"abcde\u{0301}"  →  resize(10, 3)  →  "abcd"
```

Le `é` (e + U+0301, premier cluster de la session) est perdu.

Le garde correct existe déjà ailleurs — `Screen.combine` teste bien
`cell.content == Cell.empty and !cell.grapheme` (`src/term/screen.zig:302`). Il
manque simplement des deux côtés de `grid.zig` / `cell.zig`.

**Correctif :** `return !c.grapheme and (c.content == Cell.empty or c.content == ' ') and c.style == 0;`
et idem dans `isBlank()`. Ajouter un test de non-régression : un cluster en fin
de ligne doit survivre à un aller-retour de largeur.

---

## 2. La table de styles n'est jamais recyclée, et l'échec est définitif

**Sévérité : haute — dégradation permanente déclenchable par de la sortie ordinaire.**
**Fichier :** `src/term/cell.zig:100-109`

```zig
if (self.list.items.len >= std.math.maxInt(u16)) return 0;
```

Une fois les 65535 ids consommés, `intern` renvoie 0 **pour le reste de la
session** : tout le terminal rend en style par défaut, sans message ni moyen de
récupération. `reset()` (RIS, `src/term/screen.zig:849`) ne remet pas la table à
zéro, donc même pas d'échappatoire manuelle.

Ce n'est pas un cas limite : `lolcat`, un prompt en dégradé, `btop`, une image
convertie en ANSI — tout ce qui émet du truecolor par cellule — épuise 65535
styles distincts en quelques écrans à 1440p.

Le commentaire du code annonce « Refcounting arrives with scrollback in phase 2 ».
La phase 2 est committée ; ce n'est pas fait. Voir aussi §D1.

**Correctif :** refcount par id, libéré quand une cellule est écrasée / évincée
du ring. À défaut et en attendant : vider la table sur RIS, et compacter en
balayant la grille quand l'occupation dépasse un seuil.

---

## 3. `GraphemeTable` croît sans borne

**Sévérité : moyenne — croissance mémoire monotone pilotée par de l'entrée non fiable.**
**Fichier :** `src/term/cell.zig:138-150`

Append-only assumé par le commentaire. `clear()` existe mais n'est appelé nulle
part (vérifié sur tout l'arbre), et RIS ne la vide pas. Chaque extension d'un
cluster écrit une nouvelle entrée en conservant l'ancienne : passer de 2 à 3
codepoints laisse la version à 2 en place définitivement.

`cat` d'un fichier volumineux en NFD (vietnamien, coréen décomposé) ou riche en
emoji fait monter `data` et `spans` de façon monotone sur toute la durée de vie
du process.

Le cap `max_len = 8` protège contre le texte « zalgo » — c'est bien vu — mais pas
contre le volume.

**Correctif :** recyclage conjoint avec les ids de style (§2), même mécanisme.

---

## 4. Spin CPU si le compositeur meurt

**Sévérité : moyenne.**
**Fichier :** `src/main.zig:179-184`

```zig
if (fds[0].revents & std.posix.POLL.IN != 0) {
    if (c.wl_display_read_events(win.display) < 0) break;
} else {
    c.wl_display_cancel_read(win.display);
}
_ = c.wl_display_dispatch_pending(win.display);
```

Si `revents` porte `POLLERR` ou `POLLHUP` sans `POLLIN`, on annule la lecture et
on reboucle — `poll` revient immédiatement avec le même état. Résultat : 100 %
d'un cœur au lieu d'une sortie propre. Le retour de `wl_display_dispatch_pending`
n'est jamais testé.

**Correctif :** sortir de la boucle sur `POLLERR | POLLHUP | POLLNVAL` sur le fd
Wayland, et traiter `wl_display_dispatch_pending() < 0` comme fatal.

---

## 5. UTF-8 : pas de rejet des overlongs ni des surrogates

**Sévérité : basse.**
**Fichier :** `src/vt/parser.zig:158-172`

Les plages de tête sont bien filtrées (`0xc2...0xdf` exclut les overlongs à 2
octets), mais rien ne rejette `E0 80 80` (overlong à 3 octets) ni la plage
D800–DFFF (surrogates). Ces codepoints partent tels quels vers `print()` puis
`utf8proc_charwidth`.

Pas de crash observé, et la resynchronisation sur octet invalide fonctionne — mais
c'est de l'entrée non fiable et le filet est mince.

**Correctif :** valider le codepoint assemblé avant `print()` (rejet des
surrogates et des encodages non minimaux) et émettre U+FFFD sinon.

---

## Réserves structurelles

### R1. Le reflow réalloue tout, à chaque événement de resize

**Fichiers :** `src/term/grid.zig:328` (`resizeReflow`), `src/term/grid.zig:220`
(`resizePreserve`), `src/term/screen.zig:149` (`resize`)

`resizeReflow` alloue `(rows + scrollback_max) * cols` cellules, les `memset`, et
parcourt l'intégralité du scrollback — **par événement configure**. À 240
colonnes et 10 000 lignes d'historique : ~19 Mo alloués + un balayage complet.

Et `Screen.resize` en enchaîne deux : reflow de la grille active plus
`resizePreserve` de l'autre, qui réalloue elle aussi.

Pendant un drag de fenêtre à 75 Hz, cela représente plus d'un Go/s de churn
allocateur et mémoire. Pour un projet dont la thèse est la latence, c'est le
point à mesurer en premier — vraisemblablement le pire cas de tout le programme
en l'état.

**Pistes :** réutiliser le slab quand `cols` est inchangé (redimensionnement
vertical seul, cas fréquent) ; ne reflower que le scrollback réellement visible
et différer le reste ; coalescer les configure successifs pendant un drag.

### R2. `screen.zig` atteint 1 630 lignes

Dont ~620 de tests, ce qui est sain, et les séparateurs de section maintiennent la
lisibilité. Mais SGR, modes, curseur, scrolling et device reports cohabitent dans
une seule struct. Découpage naturel au moment où la phase 3 ajoutera le protocole
clavier.

---

## Détails mineurs

- `restoreCursor` ne restaure pas `wrap_pending` (`src/term/screen.zig:558`).
- DECSET 1002 et 1003 sont fusionnés sur `.any`, ce qui perd la distinction
  entre motion-while-pressed et any-motion (`src/term/screen.zig:787`).
- `print()` avec un caractère large et `autowrap` désactivé jette le caractère au
  lieu d'écraser la dernière colonne, contrairement à xterm
  (`src/term/screen.zig:228`).
- Le titre est tronqué à 256 octets, potentiellement au milieu d'une séquence
  UTF-8 (`src/term/screen.zig:494`).
- La terminaison d'OSC par ST provoque un `escDispatch('\\')` parasite, ignoré en
  aval mais parasite quand même (`src/vt/parser.zig:91-101`).
- `Screen.resize` : si le `realloc` de `tab_stops` échoue après un reflow réussi,
  l'écran reste dans un état incohérent (`src/term/screen.zig:176`).

---

## Dérives documentation / réalité

### D1. Promesses de phase non tenues

- `src/term/cell.zig:81-84` : « Refcounting arrives with scrollback in phase 2 ».
  La phase 2 est committée, le refcounting n'existe pas. Voir §2.
- `src/term/cell.zig:142` : `TODO(phase 2 remainder)` sur le recyclage des
  graphèmes, même situation. Voir §3.
- `src/term/screen.zig:7-8` : l'en-tête annonce « Still absent (phase 2
  remainder): double-width characters — every codepoint is assumed one column
  wide, so CJK overlaps ». C'est **faux** : les caractères double largeur sont
  implémentés et testés (`writeCell`, `breakPairAt`, `width.zig`, et les tests
  lignes 1480-1615). Le commentaire est resté d'une version antérieure et induit
  en erreur dans le sens inverse de l'habituel.
