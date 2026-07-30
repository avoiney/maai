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

### Reprise du 2026-07-30, après la phase 6

| Cas | Valeur | Remarque |
|---|---|---|
| parse ASCII (4 MiB) | 26,1–27,4 ms — ~150 MiB/s | inchangé |
| truecolor SGR par cellule | 11,0–11,5 ms — ~176 MiB/s | voir ci-dessous |
| parse CJK + combinantes | 8,4 ms — 237 MiB/s | inchangé |
| reflow, largeur −1 | 11,5 ms · 19,2 MiB | inchangé, toujours ouvert |
| reflow, hauteur −1 | 0,010 ms · 0,1 MiB | inchangé |
| 50k défilements | 2,7 ms | inchangé |
| 150k styles avec ramassage | 13,9 ms | inchangé |
| **résolution des couleurs, 240×68** | **0,020 ms par trame** | nouveau cas |

Le cas truecolor est passé de 10,1 à ~11,3 ms, ce qui ressemble à une régression de
10 % introduite par l'indirection des couleurs. **Ce n'en est pas une.** Un A/B
entrelacé — worktree git sur le commit précédant le changement, six exécutions en
alternance sur la même machine au même moment — donne 11,2–11,7 ms *avant* contre
11,2–11,5 ms *après*. C'est la ligne de base de référence qui avait été mesurée sur une
machine au repos ; la machine est maintenant en usage réel. Le mécanisme allait de toute
façon dans l'autre sens : le changement retire du travail du chemin SGR.

Enseignement de méthode : un chiffre isolé comparé à un chiffre historique ne dit rien
sur une machine dont l'état a changé. Seul l'A/B entrelacé tranche, et il coûte cinq
minutes.

Le nouveau cas `render:` existe parce que le changement de la phase 6 a déplacé du
travail du temps d'analyse vers le temps de dessin, et que le dessin lie GL — donc il
échappe à ce harnais. Ce qui est mesurable, c'est l'arithmétique : trois emplacements de
couleur par cellule sur un écran de 16 320 cellules coûtent **0,020 ms par trame**, soit
0,15 % du budget de 13 ms à 75 Hz. Le coût *ajouté* est une fraction de cela, la
recherche dans la table de styles étant déjà là avant.

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

### §R1 — reflow en largeur, profilé le 2026-07-30

**Les deux pistes notées ici étaient fausses, et le profilage l'a montré.**

`perf` est inutilisable sur cette machine (`perf_event_paranoid = 4`, il faut root).
`valgrind --tool=callgrind` marche, avec deux pièges :

- il meurt en SIGILL sur le code généré pour ce Zen — recompiler avec
  `-Dcpu=x86_64_v2` ;
- `zig-out/bin/bench` était **périmé**. `installArtifact` s'accroche à l'étape par
  défaut, donc `zig build bench -Doptimize=ReleaseFast` exécutait le binaire optimisé
  depuis le cache en laissant un binaire **Debug** dans `zig-out/bin`. Mon premier
  profil ne mesurait donc rien de pertinent. Corrigé : l'étape `bench` installe
  maintenant, et `MYTERM_BENCH=<motif>` filtre les cas — un profileur braqué sur toute
  la suite ne rapporte que les cas d'analyse, qui noient le reste.

Profil de `resizeReflow` seul, en instructions :

| Ligne | Ir | Part |
|---|---|---|
| `&self.buf[(self.start + i) % self.buf.len]` (`Grid.line`) | 291,0 M | 13,4 % |
| `self.g.line(self.line_start + off / self.g.cols)` | 103,5 M | 4,8 % |
| `r.cells[off % self.g.cols]` | 41,4 M | 1,9 % |
| `@memset(slab, blankCell(0))` | 20,1 M | **0,9 %** |

Trois divisions matérielles par cellule, six en comptant la relecture de la passe
d'émission. Et le `memset` que cette section soupçonnait pèse **0,9 %** : la piste
« ne pas memset ce qu'on va réécrire » ne valait rien.

**Mais retirer les divisions n'a rien donné de mesurable** (10,7–11,4 contre
11,0–11,7 ms). Le nombre d'instructions n'est pas le temps : ce cœur a un diviseur
rapide et beaucoup d'exécution dans le désordre. Le changement est conservé — le
code est plus simple et la cellule voyage avec le pas — mais il ne faut pas le
créditer d'un gain.

Ce qui a payé vient d'une **ablation** : remplacer la passe de comptage par de
l'arithmétique fait passer de 11,8–14,5 à 8,8–9,2 ms. D'où le correctif : un drapeau
`Row.has_wide`, conservateur, permet de compter les rangées arithmétiquement quand la
ligne logique ne contient aucun caractère double largeur — seule une paire à cheval sur
une limite de rangée rend la réponse non calculable. Les builds de debug vérifient que
les deux chemins s'accordent, donc c'est la suite de tests qui attrape un drapeau
périmé, pas l'utilisateur.

A/B entrelacé, sept manches, machine en usage réel :

| | min | médiane |
|---|---|---|
| avant | 12,77 ms | ~13,5 ms |
| après | **9,79 ms** | **~11,0 ms** |

Sous le budget de trame de 13 ms à 75 Hz, mais sans marge confortable.

### §R1 — émission par `@memcpy`, le 2026-07-30

L'ablation situait la passe d'émission à ~9 ms : 2,4 M de cellules écrites une par une,
avec une branche et un stockage par cellule. Une ligne logique sans caractère double
largeur n'est qu'un **réagencement d'une suite de cellules**, donc elle se copie par
blocs : chaque copie s'arrête à la première limite atteinte — bord de la rangée source,
bord de la rangée destination, ou fin du contenu. L'index de l'anneau est calculé une
fois par bloc au lieu d'une fois par cellule. Le walker reste le chemin des lignes
contenant du double largeur, où une paire à cheval sur une limite déplace tout.

A/B entrelacé, machine calme, contre l'état d'avant tout le travail de reflow
(`1b69a71`) :

| | min |
|---|---|
| avant | 11,17 ms |
| après | **5,25 ms** |

**−53 %.** Confortablement sous le budget de trame de 13 ms à 75 Hz : un glisser de bord
latéral à 75 Hz coûte désormais 0,39 s de travail par seconde au lieu de 0,84.

Gardes ajoutées, parce qu'un chemin d'émission faux perd des données : une propriété
d'**aller-retour** (rétrécir puis réélargir doit reproduire exactement la disposition
d'origine, sur six largeurs qui coupent les blocs à des endroits différents) et une
propriété d'**équivalence des deux chemins** (même contenu, une fois avec les rangées
marquées `has_wide` pour forcer le walker — les deux dispositions doivent être
identiques).

## Le reflow n'est pas propre en aller-retour avec du double largeur

**Sévérité : moyenne — insertion silencieuse de caractères, cumulative.**
**Trouvé le 2026-07-30 par la propriété d'aller-retour ci-dessus. Antérieur au travail
de la phase 6 : vérifié en remisant le changement, l'échec persiste.**

Quand une paire double largeur ne peut pas finir une rangée, le walker la déplace
entière sur la suivante et laisse la dernière colonne blanche. **Cette colonne est
stockée comme du contenu ordinaire.** En réélargissant, elle n'est donc pas retirée :

```
"cjk 日本語 mixed…"  →  largeurs 19,13,7,3,11,20  →  "cjk 日 本語 mixed…"
```

Une espace qui n'a jamais été tapée apparaît, et l'effet s'accumule à chaque
redimensionnement.

**Correctif proposé :** distinguer le remplissage du contenu. `Cell.wide` est un `u2`
dont la valeur **3 est libre** — elle signifierait « blanc inséré pour garder une paire
entière ». `Wrap` la sauterait comme il saute déjà les cellules d'espacement, donc elle
ne redeviendrait jamais du contenu. À traiter à froid : c'est le chemin de données de
l'historique.

L'autre piste, ne reflower que l'historique atteignable, reste un changement
architectural à ne pas entamer sans besoin constaté.

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
- ~~DECSET 1002 et 1003 sont fusionnés sur `.any`, ce qui perd la distinction
  entre motion-while-pressed et any-motion~~ — **corrigé** (2026-07-30) : les
  quatre modes sont des bits indépendants dans `mouse.Modes`, et `mode()` retient
  le plus capable. Le vrai défaut était plus grave que la distinction perdue :
  `DECRST 1002` éteignait un suivi que 1003 voulait toujours.
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
