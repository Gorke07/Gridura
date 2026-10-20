<h1 align="center">Gridura</h1>

<p align="center">
  macOS 26 ve sonrası için tam ekran uygulama başlatıcı: uygulamalarınız sayfalı veya kaydırmalı bir ızgarada;
  klasörler, sürükle-bırak ile sıralama, arama ve Liquid Glass ile.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-26%2B-111?logo=apple&logoColor=white" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift&logoColor=white" alt="Swift">
  <img src="https://img.shields.io/badge/durum-erken%20%C3%B6n%20s%C3%BCr%C3%BCm-orange" alt="Erken ön sürüm">
  <img src="https://img.shields.io/badge/language-English%20%7C%20T%C3%BCrk%C3%A7e-4ade80" alt="English | Türkçe">
</p>

<p align="center">
  <a href="README.md">English</a> · <b>Türkçe</b>
</p>

---

macOS 26 (Tahoe) Launchpad'i kaldırdı. Gridura, uygulamalarınızı istediğiniz gibi düzenleyebileceğiniz ızgarayı geri
getirir: bir kısayol, kıstırma hareketi, sıcak köşe veya menü çubuğuyla açın, uygulamayı bulup başlatın ve yolunuzdan çekilsin.

> **Durum: erken ön sürüm (0.0.1).** Çekirdek çalışıyor ve otomatik arayüz testleriyle kapsanıyor, ancak gerçek
> kullanımda henüz az denendi. Pürüzler olabilir; lütfen [issue](https://github.com/Gorke07/Gridura/issues) olarak bildirin.

## Özellikler

### Izgara
- **Sayfalı veya kaydırmalı**, tam ekran veya pencerede. Sütun ve satır sayısını seçebilirsiniz.
- **Klasörler:** bir uygulamayı diğerinin üstüne bırakarak klasör oluşturun; içinde sıralayın, dışarı sürükleyip ayırın, tıklayarak yeniden adlandırın.
- **Sürükle-bırak:** simgeleri yeniden sıralayın, sayfalar arasında taşıyın (ekran kenarında bekleyerek sayfa çevirin), birden fazlasını birlikte sürükleyin.
- **Çoklu seçim:** ⌘-tıklama veya ⌘-sürükleyerek dikdörtgen seçim; menüden seçimi taşıyın, klasöre toplayın veya gizleyin.
- **Sıralama:** özel sıra, ada göre, eklenme tarihine göre veya son açılma tarihine göre. **Yeniden düzenle** boşlukları doldurur;
  ada, tarihe, son kullanıma veya simge rengine göre sıralayabilir, klasörleri koruyabilir veya dağıtabilir, Apple uygulamalarını başa ya da sona alabilir.
- **Arka plan:** bulanıklaştırılmış duvar kağıdınız (Ekran Kaydı izni gerekir) veya beş yoğunlukta Liquid Glass malzemesi.

### Arama
- Herhangi bir yerde yazarak arayın; önce alana tıklamanız gerekmez. Eşleşme büyük/küçük harf ve aksan ayrımı yapmaz (`masaustu`, *Masaüstü*'nü bulur).
- ↩ ilk sonucu açar. Ok tuşları seçimi taşır. Esc önce aramayı temizler, sonra başlatıcıyı kapatır.

### Açma yolları
- **Genel kısayol** (varsayılan ⌥Boşluk, değiştirilebilir), **F4 tuşu**, **trackpad ile kıstırma** (3, 4 veya 5 parmak),
  **sıcak köşeler** veya **menü çubuğu simgesi**.
- Boş bir yere tıklayarak veya Esc ile kapatın; boş yerde kaydırarak sayfa değiştirin.

### Uygulama yönetimi
- Hiç açmadığınız uygulamaları **gizleyin**, **yeniden adlandırın**; bağlam menüsünden **Finder'da göster** veya **bilgi al**.
- Bir uygulamayı artıklarıyla (önbellek, tercihler, konteynerler…) birlikte **silin** — hiçbir şey Çöp Kutusu'na taşınmadan önce
  bir tarama her şeyi listeler. İsterseniz ⌥ tuşunu basılı tutarak silme moduna girebilirsiniz.
- Düzeninizi **yedekleyin ve geri yükleyin**, ya da eski sistem Launchpad düzenini **içe aktarın**.

### Ayrıntılar
- İngilizce ve Türkçe arayüz; isteğe bağlı girişte başlatma ve menü çubuğu simgesi.
- Seçebileceğiniz beş uygulama simgesi, hepsi bu proje için çizildi.
- İmzalı sürümlerle [Sparkle](https://sparkle-project.org) üzerinden güncelleme.

## Gereksinimler

- macOS 26.0 veya üzeri (Apple silikon ya da Intel).
- İsteğe bağlı izinler: **Erişilebilirlik** (F4 tuşu ve trackpad kıstırma), **Ekran Kaydı** (duvar kağıdı arka planı),
  **Tam Disk Erişimi** (silerken tüm artıkları bulmak). Gridura yalnızca ilgili özelliği açtığınızda sorar.

## Kaynaktan derleme

Xcode 26 ve [XcodeGen](https://github.com/yonaskolb/XcodeGen) gerekir.

```bash
git clone https://github.com/Gorke07/Gridura.git
cd Gridura
xcodegen generate          # project.yml'den Gridura.xcodeproj üretir
open Gridura.xcodeproj     # "Gridura" şemasını çalıştırın
```

`Gridura.xcodeproj` üretilmiş bir dosyadır; proje dosyası yerine `project.yml` dosyasını değiştirin.

### Testler

Debug derlemeleri, gerçek başlatıcıyı gerçek fare ve klavye olaylarıyla süren bir arayüz test düzeneği içerir.
Geçici bir depo olmadan çalışmayı reddeder, böylece kendi kitaplığınıza hiç dokunulmaz:

```bash
mkdir /tmp/gridura-test
GRIDURA_SELFTEST=realdrag-app GRIDURA_STORE_DIR=/tmp/gridura-test \
  "$(find ~/Library/Developer/Xcode/DerivedData -path '*Debug/Gridura.app/Contents/MacOS/Gridura' | head -1)"
cat /tmp/gridura_selftest.log
```

Modlar arasında `drag`, `merge`, `multi`, `folder`, `hide`, `realdrag-app`, `realclick`, `realsearch`, `realrename`,
`tour` ve `shot-*` ekran görüntüsü modları vardır (bkz. `Gridura/App/SelfTest.swift`). Gerçek olay modları, onları başlatan
terminal veya Xcode için Erişilebilirlik izni ister.

## Proje yapısı

| Yol | İçerik |
|---|---|
| `Gridura/App` | uygulama yaşam döngüsü, menü çubuğu, güncelleme yöneticisi, kendi testleri |
| `Gridura/Presentation` | pencere, ızgara, klasörler, sürükle-bırak, arama görünümü |
| `Gridura/Model` | Core Data deposu, düzen normalleştirme, arama, uygulama tarama |
| `Gridura/Input` | kısayol, F4, trackpad kıstırma, sıcak köşeler |
| `Gridura/Settings` | ayarlar penceresi ve ilk kurulum |
| `Gridura/Uninstall` | silme penceresi ve artık taraması |
| `Scripts` | simge üreticisi ve sürüm betiği |
| `docs` | uygulama durumu ve sürüm rehberi |

## Sürüm alma

Bkz. [`docs/release.md`](docs/release.md). Kısaca: `project.yml` içindeki sürümü artırın, iki değişiklik günlüğünü güncelleyin,
`Scripts/build-release.sh` çalıştırın, GitHub sürümünü yayımlayın, ardından `appcast.xml` dosyasını push'layın.

## Katkı

Issue ve pull request'ler memnuniyetle karşılanır. Ne beklediğinizi ve ne olduğunu anlatın, macOS sürümünüzü ekleyin.
Pull request açmadan önce değiştirdiğiniz alanı kapsayan testleri çalıştırın.

## Lisans

Gridura [MIT Lisansı](LICENSE) ile yayımlanır. Üçüncü taraf bileşenler
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) dosyasında listelenir.

## Teşekkür

Güncellemeler için [Sparkle](https://sparkle-project.org) ile yapıldı. Gridura bağımsız bir projedir ve Apple ile bağlantısı yoktur.
