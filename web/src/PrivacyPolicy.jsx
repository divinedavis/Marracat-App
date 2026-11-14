// The one Marracat privacy policy, served at https://marracat.com/#/privacy.
// The App Store listing links here, the iOS app's Privacy sheet
// (Marracat/Views/AccountPanel.swift) summarises it, and
// app-store/app-privacy-answers.md must agree with it. Every statement is
// checked against the code it describes; change them together.

const EMAIL = "privacy@marracat.com";
const Mail = () => <a href={`mailto:${EMAIL}`}>{EMAIL}</a>;

export default function PrivacyPolicy() {
  return (
    <div className="policy">
      <p className="policy-updated">Last updated: November 12, 2026</p>
      <p>
        This policy covers marracat.com and the Marracat iPhone app. Marracat
        helps you find products from independent brands and buy them through
        each brand’s own checkout. It says what we collect, who can see it, how
        long we keep it and how to have it deleted.
      </p>

      <h2>Without an account</h2>
      <p>
        You can browse and shop without signing in. On the website your cart,
        saved items and the checkout details you fill in (name, email, phone and
        shipping address) are kept in your browser’s local storage, along with
        the random id described under Visits, whether you dismissed the app banner
        or the app suggestion on product pages (the owner’s own browsers also
        carry a flag that leaves them out of visitor counts). In the app, guest activity (saved
        items, lists, searches, recently viewed products, cart and checkout
        details) stays on your iPhone. Clearing the browser’s site data or
        deleting the app removes it.
      </p>

      <h2>Your account</h2>
      <p>
        If you sign in with Google or Apple, we receive your account identifier,
        your name and your email address when the provider shares them. Apple
        lets you hide your email address. We never receive your password or your
        mail, contacts or activity from other apps. The website keeps you signed
        in with a secure session cookie; the app keeps its session in the iPhone
        Keychain. If you sign in with Apple and with Google using the same
        email address, both open the same Marracat account; we keep a record of
        which sign-ins belong to it. An address hidden with Apple’s Hide My Email
        never matches another account.
      </p>
      <p>
        On marracat.com you can also add a passkey to your account, on your
        account page, and sign in with your face, fingerprint or device PIN.
        The passkey’s private key stays on your device or in your password
        manager; we keep only its public key, a random identifier, the kind of
        device it was added from, and when it was added and last used.
        Removing it there, or deleting your account, deletes them.
      </p>
      <p>
        While you are signed in to the app, your saved items and lists, searches,
        recently viewed products, hidden recommendations, your personalization
        setting and checkout records sync to Marracat’s server so they follow you
        to another device. Each profile keeps up to 500 saved items, 100 recent
        views, 30 recent searches, 500 hidden recommendations and 200 checkout
        records. A cover photo you pick for a list from your photo library stays
        on your phone and is never uploaded. Guest activity is added to your
        account only if you choose to bring it when you sign in.
      </p>
      <p>
        So you can find them from Spotlight and Siri, the app adds your saved
        items, the brands you follow and, while personalization is on, the
        products you viewed recently to your iPhone’s own search index, along
        with Marracat’s featured brands. That index is kept on your iPhone by
        iOS; nothing from it is sent to Marracat. Signing out or deleting your
        account removes your items from it, and deleting the app removes all of it.
      </p>
      <p>
        Marracat’s Home Screen and Lock Screen widgets read a small copy the app
        keeps on your iPhone, in storage shared only with its own widgets: price
        drops on your saved items, Marracat’s featured brands and the delivery
        status of your recent orders, with small product photos. Nothing in it is
        sent to Marracat. Signing out or deleting your account erases it, and
        deleting the app removes it.
      </p>
      <p>
        On marracat.com, your browser keeps your last 30 searches and the last
        100 products you opened in its own storage, so a short search can start
        with a product or two that fits what you have been looking at. They
        stay in that browser and are never sent to Marracat; clearing the
        site’s data in your browser removes them.
        Your browser also keeps a copy of the product catalog and of the site
        itself, so a later visit opens quickly and works without a connection.
        These hold nothing about you, and clearing the site’s data removes them
        too.
      </p>
      <p>
        Recommendations use your activity in Marracat, with more weight for likes
        than views and for recent activity. We do not infer sensitive personal
        traits. In the You tab you can turn personalization off (which clears
        searches and views and stops recording them), clear history, reset
        hidden recommendations, sign out or delete your account.
      </p>

      <h2>Comments, profiles and friends</h2>
      <p>
        Since September 19, 2026, signed-in shoppers can comment on products, add
        friends and send products to them. Using these is optional, and before
        you post or send anything you agree to our community guidelines; we
        record when you agreed.
      </p>
      <ul>
        <li>
          <strong>Your profile</strong> is a display name and a unique @handle.
          The name starts as your first name and last initial from your sign-in
          and you can change both. Anyone, signed in or not, can see the profile
          of a handle they open, and signed-in shoppers can find you by name or
          handle. Your email and account identifier are never shown to anyone.
        </li>
        <li>
          <strong>Comments</strong> are public. Anyone viewing that product on the
          website or in the app can read them, with your display name and handle.
          We store the comment, the product, any comment it replies to, and when
          you posted it. You can delete your own comment at any time: its text is
          erased, and if it had replies a placeholder that names no one keeps the
          thread together.
        </li>
        <li>
          <strong>Friends.</strong> We store friend requests and friendships.
          Your friends list and pending requests are visible only to you.
        </li>
        <li>
          <strong>Blocking</strong> is private; we do not tell the other person.
          It ends any friendship or request between you and hides each of you
          from the other’s comments, profile, search results, friend requests and
          shares.
        </li>
        <li>
          <strong>Sending a product to a friend is end-to-end encrypted.</strong>{" "}
          Each device you use makes its own key pair. The private key never leaves
          that device (the iPhone Keychain, or your browser’s storage); only the
          public key is sent to us, for up to ten devices. The product and any
          note you add (up to 280 characters) are encrypted on your device
          separately for each of your friend’s devices, so our server stores only
          who sent a share to whom, when, whether it has been opened, and
          encrypted data it cannot read. Only friends can send you products.
        </li>
        <li>
          <strong>Screening.</strong> Comments, names and handles are checked by
          an automatic word filter on our server, and share notes by the same
          filter on your device before they are encrypted. No outside service or
          AI reads what you write.
        </li>
        <li>
          <strong>Reports and moderation.</strong> You can report a comment, a
          person or a share. We store who reported what, when, and the reason if
          you give one. A reported comment is hidden from everyone except its
          author until we review it. Because we cannot read shares, reporting one
          sends us the product and note your device decrypted; that is the only
          way we ever see a share’s content. The Marracat team reviews reports,
          aiming to act within 24 hours, and may restore the content, remove it,
          or stop an account from posting.
        </li>
      </ul>

      <h2>Checkout and orders</h2>
      <p>
        Purchases happen in each brand’s own Shopify checkout, under that brand’s
        privacy, shipping and return policies. Card details go to the brand’s
        checkout and never reach Marracat. When you check out several brands at
        once, your name, email, phone and shipping address are sent to each brand in
        your cart to prepare its checkout: from the app they go straight from
        your phone, and from the website they pass through our server only
        because browsers cannot reach the stores directly. We do not store or
        log them.
      </p>
      <p>
        When an in-app checkout reports completion, we save the brand, products,
        quantities, date and displayed subtotal, and if Shopify provides them the
        order reference, total and currency. We never save card details or
        shipping addresses from checkout. Purchases made on a brand’s own website
        may not report back to us.
      </p>
      <h3>Your Marracat order email</h3>
      <p>
        Where it is switched on for your account, the app gives a brand’s
        checkout a private Marracat address (like u-…@orders.marracat.com)
        instead of your own email. The brand still sees your name, phone and
        shipping address, but not your email address. The brand’s emails to that
        address come to our server, which forwards them to your own email
        address, labeled “via Marracat”, with replies going back to the brand.
        From each email we read the order number, the brand’s order status link,
        the carrier and the tracking number, and keep those so the app can show
        your order’s progress. We store the private address, the email we
        forward to, and those readings. The email itself is kept only until it
        has been forwarded (at most three days, if forwarding keeps failing).
        Tracking numbers are sent to 17TRACK, a shipment-tracking service, so
        we can tell you when a package is out for delivery or delivered.
        Deleting your account deletes the address and everything received for
        it; mail sent to it afterwards is refused.
      </p>
      <p>
        If you aren’t signed in, the app can still give brands a private order
        address. It belongs to a random key for your copy of the app (we store
        only a one-way hash of that key), not to an account, so there is no
        inbox to forward to: we read the order number, status link, carrier and
        tracking number as above, update your orders in the app and notify this
        iPhone, and keep each email itself for at most three days in case you
        sign in. When you sign in on that iPhone, the address and what it
        received move to your account and waiting emails are forwarded to your
        account’s email; an account that already has an address keeps it, and
        the other one keeps receiving that order’s emails without being given
        out again. A signed-out address that receives nothing for 180 days is
        deleted with what it received, and deleting your account also deletes
        the one on the iPhone you delete it from.
      </p>
      <h3>Order tracking</h3>
      <p>
        When you pay a brand on a checkout the app built for you, the app sends
        our server that checkout’s reference, the brand, and Shopify’s order
        reference, tied to a random key for your copy of the app (not your
        account). Our server asks the brand’s store for the order’s status page
        and reads it now and then for the order’s progress, carrier and tracking
        number, which it keeps so the app can show them and notify you. We don’t
        keep the page itself. Tracking stops when the order is delivered or after
        30 days, and deleting your account or the app’s data removes it.
      </p>
      <h3>Live Activities</h3>
      <p>
        On iPhone, an order that is out for delivery or due today can show live
        on the Lock Screen and in the Dynamic Island. For that, the app gives our
        server the tokens Apple issues for starting and updating a Live
        Activity, tied to the same random key for your copy of the app (not your
        account), and our server sends Apple the brand, item, delivery status,
        carrier and expected time of today’s orders. You can turn this off in
        the app under You › Notifications, or for Marracat in the iPhone’s
        Settings; turning it off ends a running one.
      </p>
      <h3>Restock alerts</h3>
      <p>
        Restock alerts need a Marracat account. When you ask to hear when a
        sold-out item is back, we store the item (and the option you picked)
        with your account, and check the brand’s store for it every few
        minutes. When it’s back we send one email to your account’s email
        address and, if you allowed notifications, a notification to each iPhone
        signed in to your account. To know which iPhones those are, we keep the
        app’s notification token with a random key for each copy of the app,
        linked to your account while you’re signed in there; signing out unlinks
        it. Removing an alert, or deleting your account, deletes it.
      </p>
      <p>
        On marracat.com you can also turn on notifications for a browser, on
        your account page. We then keep that browser’s notification address
        and encryption keys (issued by Apple, Google, Mozilla or Microsoft,
        whichever runs your browser’s notification service) with your account,
        and send your price-drop, sale and new-arrival alerts through that
        service, encrypted so only your browser can read them. Turning
        notifications off there, or deleting your account, deletes them.
      </p>
      <h3>Recommendations and AI on your iPhone</h3>
      <p>
        The app finds products by meaning, suggests similar looks and styles,
        reorders Home around what you browse, reminds you to restock things you
        buy regularly, and watches for your written interests. All of that runs on
        your iPhone: what you look at and for how long, what you save, what you
        type into search and the interests you write are learned on the phone,
        and that learning never leaves it. (Separately, the app reports what you
        do in it to our own server for counting, as described under What you do
        on the website and in the app.) To do it, the app downloads a language model and a
        description of every product from us, once, over Wi-Fi or cellular (not in
        Low Data Mode). Turning off Personalized recommendations in account
        settings stops this learning and clears it.
      </p>
      <h3>Frequently bought together</h3>
      <p>
        When products are added to a cart together or bought together, the app
        sends us which products they were, tied to a random key for your copy of
        the app, not your account. We count how many different copies of the app
        put the same pair together, and only show a pair once at least three have,
        so no one shopper’s choices show on their own.
      </p>
      <h3>Visits</h3>
      <p>
        To count how many people use Marracat and how many come back, the
        website keeps a random id in your browser and the app uses its random
        key for your copy of the app. Once a day we record that id (stored only
        as a one-way hash), whether it was the website or the app, the app’s
        version, and, on your first visit, the site that sent you. We don’t
        record your IP address or device for this. Clearing your browser data
        resets the website’s id.
      </p>
      <h3>What you do on the website and in the app</h3>
      <p>
        To learn which products, brands and features help people, the website
        and the app tell our own server what you do in them, tied to the same
        random id described under Visits (the app’s random key for your copy of
        the app), stored only as a one-way hash. That covers: opening the app
        and roughly how long you used it (in ranges, such as 1 to 3 minutes);
        which screens and products you open, where you opened a product from and
        roughly how long you looked; searches (the words you searched, in lower
        case, and how many products matched); filters and sorting you choose;
        saving and unsaving products, lists, following brands and turning
        restock, price, sale or interest alerts on or off; adding to and
        removing from your cart; starting, finishing or leaving a checkout
        (which brand, how, the number of items and the subtotal in a range,
        never your name, email or address); sharing (what kind of thing, and
        which product or brand); posting a comment (that you did, not what you
        wrote); opening a notification (its kind); recommendation rows you see
        and tap; opening photos or a quality label; and starting sign-in,
        signing in or making an account (only whether it was Apple, Google,
        email or a passkey). We also record the app’s build number, whether it
        was the website or the app, and whether you were signed in. If you
        were, we store a one-way keyed hash of your account so one person’s
        steps can be counted together, never your account identifier, email or
        name. A search that looks like an email address or a long number is not
        kept, and no other text you type is sent. We don’t record your IP
        address for this, no outside analytics company receives it, and we keep
        these records for 180 days.
      </p>
      <h3>Website speed</h3>
      <p>
        When you leave a page, the website sends us how long that page took to
        load and respond, as your browser measured it, so we can make it faster.
        Each timing is kept as a range (for example “1.5 to 2.5 seconds”) with
        the kind of page it was. It is not tied to you: no account, device
        identifier or IP address is kept with it. We keep these for 90 days.
      </p>
      <h3>App performance</h3>
      <p>
        iOS gives the app a daily report of how it performed on your iPhone (how
        long it took to open, any freezes or crashes, and how much memory it
        used), and the app sends that report to us so we can make it faster. It
        holds timings and counts, not your activity or anything you typed, and is
        tied to a random key for your copy of the app, not your account. We keep
        these reports for 90 days.
      </p>
      <h3>Late shipments</h3>
      <p>
        If you mark an order as a late shipment, the app sends our server the
        brand and a reference to that order, tied to the same random key for
        your copy of the app. We store the brand, the time and a one-way hash of
        the order reference, never the order itself, to see which brands often
        ship late. Tapping again takes the report back, and deleting your account
        removes this phone’s reports.
      </p>

      <h2>Server logs</h2>
      <p>
        Like every website, our web server records each request: your IP
        address, the time, the page or data requested, the referring page and
        your browser’s user-agent. The app’s requests also say which app build
        is asking and whether it came from the App Store or TestFlight. We use
        these logs to keep Marracat running and secure, to stop abuse, and to
        count visitors and app launches. Those counts are totals only; they name
        no one. Logs are deleted automatically after about two weeks.
      </p>

      <h2>Who else receives information</h2>
      <ul>
        <li>
          <strong>Google and Apple</strong>, when you sign in with them.
        </li>
        <li>
          <strong>Brands and Shopify</strong>, when you check out, as described
          above.
        </li>
        <li>
          <strong>17TRACK</strong>, which receives the carrier and tracking
          number of orders placed with your Marracat order email, to report
          delivery progress.
        </li>
        <li>
          <strong>Brands’ image hosts</strong>, which receive normal web request
          information (such as your IP address) when product photos load.
        </li>
        <li>
          <strong>DigitalOcean</strong>, which hosts our server and its database
          in the United States.
        </li>
      </ul>
      <p>
        We do not sell or share personal information for advertising, we run no
        ads or analytics SDKs, and we do not track you across other companies’
        apps or websites.
      </p>

      <h2>How long we keep it</h2>
      <p>
        Account data, synced activity, your profile, comments, friends and shares
        are kept until you remove them or delete your account. Reports are kept
        after they are resolved as a record of what was moderated, unless the
        reporter’s account is deleted. Server logs are kept for about two weeks,
        and the website’s and app’s records of what you do in them (searches,
        views, saves, cart and checkout steps) for 180 days.
      </p>

      <h2>Deleting your account</h2>
      <p>
        In the app, open You, then Account settings, then Delete account. You
        confirm with the same Apple or Google sign-in; if you have ever signed in
        to the account with Apple, you confirm with Apple and we also revoke
        Marracat’s Sign in with Apple access. Deletion removes your
        account, sessions, synced activity and checkout records, your profile and
        handle, friends and requests, blocks, device keys, every share you sent
        or received, the reports you made and your guidelines agreement. Your
        comments are erased; replies other people wrote to them stay under a
        placeholder that does not name you. It does not cancel orders or delete
        data held by brands, Apple or Google. On the website, open
        Account, then Delete account, and confirm with a code we email to the
        account’s address; an account that signs in with Apple is deleted in
        the app, or email <Mail /> and we will delete it for you.
      </p>

      <h2>Your rights</h2>
      <p>
        Wherever you live, you can ask us for a copy of the personal information
        we hold about you, to correct it, or to delete it. Email <Mail /> from the
        address on your account; we will confirm it is you and respond within 30
        days. We will not treat you differently for making a request.
      </p>
      <ul>
        <li>
          <strong>California (CCPA/CPRA).</strong> You have the right to know,
          access, correct and delete your personal information, and to opt out of
          its sale or sharing. We do not sell or share it, and we do not use
          sensitive personal information to infer characteristics about you. In
          the past 12 months we collected identifiers (name, email, account
          identifier, IP address), commercial information (checkout records),
          internet activity (searches, views and other activity in the app and on the website, server logs) and the
          content you post, from you and your devices, for the purposes above.
          You may use an authorised agent.
        </li>
        <li>
          <strong>EEA and UK (GDPR / UK GDPR).</strong> We use your information to
          provide the service you asked for (your account, sync, comments,
          friends and shares), for our legitimate interests (security, abuse
          prevention and moderation, counting visits), with your consent
          (personalization, which you can turn off at any time), and to meet
          legal obligations. You can also object to or restrict processing, and
          complain to your local data protection authority. Your information is
          stored and processed in the United States.
        </li>
      </ul>

      <h2>Children</h2>
      <p>
        Marracat is not directed at children under 13, and we do not knowingly
        collect their information.
      </p>

      <h2>Changes and contact</h2>
      <p>
        If this policy changes in a way that matters, we will update the date at
        the top. Questions, requests or reports: <Mail />.
      </p>
    </div>
  );
}
