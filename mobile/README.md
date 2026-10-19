# Horus Hotel — application Android (Flutter)

Coque Flutter qui affiche l'application web Horus Hotel (`https://guyayekkweeli-glitch.github.io/horus-hotel/`)
et ajoute les fonctions natives :

- impression des tickets, reçus, clôtures et factures via le service d'impression Android
  (imprimantes Wi-Fi, et imprimantes thermiques Bluetooth via une appli de service d'impression comme RawBT) ;
- envoi de photos (appareil photo ou galerie) pour les chambres, produits, logo et justificatifs ;
- liens WhatsApp, téléphone et e-mail ouverts dans les applications du téléphone ;
- écran « Pas de connexion » avec reprise automatique au retour du réseau ;
- bouton retour Android : ferme la fenêtre ouverte, puis revient en arrière.

Toutes les mises à jour de l'application web sont visibles immédiatement dans l'application, sans republier.

## Compilation

Automatique : chaque envoi qui modifie `mobile/` lance le workflow GitHub Actions « Application Android (Flutter) »,
qui produit `app-release.apk` (onglet Actions → dernière exécution → Artifacts).

En local :

```
cd mobile
flutter create --platforms=android --org app.horushotel --project-name horus_hotel .
flutter pub get
dart run flutter_launcher_icons
flutter build apk --release
```

## Publication Play Store (à faire)

1. Créer une clé de signature (keystore) et la garder précieusement.
2. Construire un App Bundle : `flutter build appbundle --release` signé avec cette clé.
3. Compte Google Play Console (25 $ une fois), fiche de l'application, politique de confidentialité, captures d'écran.
