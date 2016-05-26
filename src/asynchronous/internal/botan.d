/**
 * TLS support.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.internal.botan;

import std.socket : SocketOSException;
import std.typecons : Rebindable, rebindable;
import botan.math.bigint.bigint;
import botan.algo_base.symkey;
import botan.tls.credentials_manager : TLSCredentialsManager;
import botan.cert.x509.x509cert;
import botan.filters.data_src : DataSource, DataSourceStream;
import botan.rng.auto_rng : RandomNumberGenerator, AutoSeededRNG;
import botan.pubkey.pkcs8 : loadKey, PrivateKey;
import botan.tls.server : TLSServer, TLSChannel;
import botan.tls.client : TLSClient;
import botan.tls.session_manager;
import botan.tls.policy;
import asynchronous.tls;
import asynchronous.transports : BaseTransport, Transport;
import asynchronous.protocols : Protocol;
import asynchronous.events : EventLoop;
import asynchronous.futures : Waiter;

/**
 * TLS protocol.
 *
 * Implementation of TLS.
 */
package final class BotanTLSProtocol : TLSProtocol
{
    private EventLoop eventLoop;
    private Protocol protocol;
    private TLSTransport tlsTransport;
    private BotanTLSContext tlsContext;
    private TLSChannel channel;
    private Waiter waiter;
    private bool inHandshake = true;
    private bool inShutdown;
    private Rebindable!(const TLSSession) session;

    this(EventLoop eventLoop,
         Protocol protocol,
         BotanTLSContext tlsContext = null,
         Waiter waiter = null,
         bool serverSide = false,
         string serverHostname = null)
    {
        this.eventLoop = eventLoop;
        this.protocol = protocol;
        this.tlsTransport = new TLSTransport(eventLoop,
                                                     this,
                                                     this.protocol);
        this.waiter = waiter;

        this.tlsContext = tlsContext;
        assert(tlsContext !is null);

        this.channel = new TLSServer(&outputCb,
                                     &dataCb,
                                     delegate void(in TLSAlert, in ubyte[]) {},
                                     &onHandshakeComplete,
                                     this.tlsContext.sessionManager,
                                     this.tlsContext,
                                     this.tlsContext.policy,
                                     this.tlsContext.rng);
    }

    /**
     * Called when the low-level connection is made.
     * Start the SSL handshake.
     */
    void connectionMade(BaseTransport transport)
    {
        this.transport = cast(Transport) transport;
    }

    /**
     * Called when the low-level connection is lost or closed.
     * The argument is an exception object or $(D_KEYWORD null)
     * (the latter meaning a regular EOF is received or the
     * connection was aborted or closed).
     */
    void connectionLost(Exception exception)
    {
        if (session !is null)
        {
            session = null;
            eventLoop.callSoon(&protocol.connectionLost, exception);
        }
        transport = null;
        tlsTransport = null;
    }

    /**
     * Called when the low-level transport's buffer goes over
     * the high-water mark.
     */
    void pauseWriting()
    {
        protocol.pauseWriting();
    }

    /**
     * Called when the low-level transport's buffer drains below
     * the low-water mark.
     */
    void resumeWriting()
    {
        protocol.resumeWriting();
    }

    protected override void startShutdown()
    {
        if (!inShutdown)
        {
            inShutdown = true;
            channel.close();
        }
    }

    void dataReceived(const(void)[] data)
    {
        channel.receivedData(cast(ubyte*) data, data.length);
    }

    bool eofReceived()
    {
        return true;
    }

    protected override void writeAppdata(const(void)[] data)
    {
        channel.send(cast(string) data);
    }

    private void wakeupWaiter(Exception exception = null)
    {
        if (waiter !is null && !waiter.cancelled)
        {
            if (exception is null)
            {
                waiter.setResult();
            }
            else
            {
                waiter.setException(exception);
            }
        }
        waiter = null;
    }

    private void outputCb(in ubyte[] data)
    {
        if (inHandshake)
        {
            try
            {
                // If Firefox doesn't trust the issuer, it just closes the connection,
                // that causes a crash with a system error (like "Program exited
                // with code -13") when trying to write to the transport.
                transport.getExtraInfo!"peername";
            }
            catch (SocketOSException e)
            {
                transport.close();
                wakeupWaiter(new TLSHandshakeException("Peer closed connection."));
                return;
            }
        }
        transport.write(data);
    }

    private void dataCb(in ubyte[] data)
    {
        protocol.dataReceived(data);
    }

    private bool onHandshakeComplete(in TLSSession session)
    {
        this.session = rebindable(session);
        inHandshake = false;

        protocol.connectionMade(tlsTransport);
        wakeupWaiter();

        return !is(typeof(tlsContext.sessionManager) == TLSSessionManagerNoop);
    }
}

/**
 * Basic credentials manager.
 *
 * A type is a fairly static value that represents the general nature
 * of the transaction occuring. Currently used values are "tls-client"
 * and "tls-server". Context represents a hostname, email address,
 * username, or other identifier.
 */
package final class BotanTLSContext : TLSCredentialsManager, TLSContext
{
    private Unique!PrivateKey key;
    private Vector!X509Certificate certs;
    private Vector!CertificateStore stores;
    private ProtocolVersion protocolVersion;
    private AutoSeededRNG rng;
    private TLSSessionManager sessionManager;
    private TLSPolicy policy;

    /**
     * Constructor.
     *
     * Params:
     *  ver = the protocol version.
     *
     * See_Also: $(D_PSYMBOL ProtocolVersion)
     */
    this(ProtocolVersion ver = ProtocolVersion.TLSv1_2,
        TLSSessionManager sessionManager = null, TLSPolicy policy = null)
    {
        protocolVersion = ver;
        rng = new AutoSeededRNG();
        if (sessionManager is null)
        {
            this.sessionManager = new TLSSessionManagerInMemory(rng);
        }
        else
        {
            this.sessionManager = sessionManager;
        }
        if (policy is null)
        {
            this.policy = new TLSPolicy();
        }
        else
        {
            this.policy = policy;
        }
    }

    /**
     * Load a set of "certification authority" (CA) certificates used to validate
     * other peers' certificates.
     *
     * Params:
     *  CAFile = the path to a file of concatenated CA certificates in PEM format.
     */
    void loadVerifyLocations(in string CAFile)
    {
        auto cs = new CertificateStoreInMemory();

        certs.pushBack(X509Certificate(CAFile));
        cs.addCertificate(certs[$-1]);
        stores.pushBack(cs);
    }

    /**
     * Load a private key and the corresponding certificate.
     *
     * If you want, you can load only your certificate with this method and then
     * load all CA certificates with $(D_PSYMBOL loadVerifyLocations).
     *
     * Params:
     *  certFile = the path to a single file in PEM format containing the
     *             certificate as well as any number of CA certificates needed to
     *             establish the certificate's authenticity.
     *  keyFile  = a file containing the PKCS#8 format private key.
     */
    void loadCertChain(in string certFile, in string keyFile)
    {
        auto cs = new CertificateStoreInMemory();
        auto inp = DataSourceStream(certFile);
        Vector!X509Certificate certs;

        this.key = loadKey(keyFile, rng);

        // The first certificate in the chain is the winner.
        certs.pushBack(X509Certificate(cast(DataSource) inp));
        // The following ones if available should be just intermediate and probably
        // root certificates. If it isn't the case it is the user's fault.
        while (!inp.endOfData())
        {
            try
            {
                auto cert = X509Certificate(cast(DataSource) inp);
                certs.pushBack(cert);
                cs.addCertificate(cert);
            }
            catch (Exception e)
            {
                // endOfData returns true first after a failed try to read
            }
        }
        if (certs.length > 1)
        { // There is at least one intermediate certificate in the store
            stores.pushBack(cs);
        }
        // Prepend the available certificates with the new one(s)
        certs ~= this.certs;
        this.certs = certs;
    }

    /**
     * Return a list of the certificates of CAs that we trust in this
     * type/context.
     *
     * Params:
     *  type    = specifies the type of operation occuring.
     *  context = specifies a context relative to type. For instance
     *            for type "tls-client", context specifies the servers name.
     */
    protected override Vector!CertificateStore trustedCertificateAuthorities(in string type,
        in string context)
    {
        return stores.dup;
    }

    /**
     * Check the certificate chain is valid up to a trusted root, and
     * optionally (if hostname != "") that the hostname given is
     * consistent with the leaf certificate.
     *
     * This function should throw new an exception derived from
     * $(D Exception) with an informative what() result if the
     * certificate chain cannot be verified.
     *
     * Params:
     *  type               = specifies the type of operation occuring.
     *  purported_hostname = specifies the purported hostname.
     *  cert_chain         = specifies a certificate chain leading to a
     *                       trusted root CA certificate.
     */
    protected override void verifyCertificateChain(in string type,
        in string purported_hostname, const ref Vector!X509Certificate cert_chain)
    {
        super.verifyCertificateChain(type, purported_hostname, cert_chain);
    }

    /**
     * Return a cert chain we can use, ordered from leaf to root,
     * or else an empty vector.
     *
     * It is assumed that the caller can get the private key of the
     * leaf with $(D_PSYMBOL privateKeyFor).
     *
     * Params:
     *  cert_key_types = specifies the key types desired ("RSA",
     *                   "DSA", "ECDSA", etc), or empty if there
     *                   is no preference by the caller.
     *  type           = specifies the type of operation occuring.
     *  context        = specifies a context relative to type.
     */
     protected override Vector!X509Certificate certChain(const ref Vector!string cert_key_types,
        in string type, in string context)
    {
        Vector!X509Certificate chain;
        
        if (type == "tls-server")
        {
            auto haveMatch = false;
            foreach (certKeyType; cert_key_types[])
            {
                if (certKeyType == key.algoName)
                {
                    haveMatch = true;
                    break;
                }
            }
            
            if (haveMatch)
            {
                foreach (cert; certs)
                {
                    chain.pushBack(cert);
                }
            }
        }
        
        return chain.move();
     }

    /**
     * Return a cert chain we can use, ordered from leaf to root,
     * or else an empty vector.
     *
     * It is assumed that the caller can get the private key of the
     * leaf with $(D_PSYMBOL privateKeyFor).
     *
     * Params:
     *  cert_key_type = specifies the type of key requested
     *                  ("RSA", "DSA", "ECDSA", etc).
     *  type          = specifies the type of operation occuring.
     *  context       = specifies a context relative to type.
     */
    protected override Vector!X509Certificate certChainSingleType(in string cert_key_type,
        in string type, in string context)
    {
        return super.certChainSingleType(cert_key_type, type, context);
    }

    /**
    * Notes: this object should retain ownership of the returned key;
    *        it should not be deleted by the caller.
    * 
    * Params:
    *  cert    = as returned by cert_chain.
    *  type    = specifies the type of operation occuring.
    *  context = specifies a context relative to type.
    * 
    * Returns: private key associated with this certificate if we should
    *          use it with this context. 
    */
    protected override PrivateKey privateKeyFor(in X509Certificate cert,
        in string type, in string context)
    {
        return *key;
    }

    /**
     * Params:
     *  type    = specifies the type of operation occuring.
     *  context = specifies a context relative to type.
     *
     * Returns: $(D_KEYWORD true) if we should attempt SRP authentication.
     */
    protected override bool attemptSrp(in string type, in string context)
    {
        return super.attemptSrp(type, context);
    }

    /**
     * Params:
     *  type    = specifies the type of operation occuring.
     *  context = specifies a context relative to type.
     *
     * Returns: identifier for client-side SRP auth, if available
     *          for this type/context. Should return empty string
     *          if password auth not desired/available.
     */
    protected override string srpIdentifier(in string type, in string context)
    {
        return super.srpIdentifier(type, context);
    }

    /**
     * Params:
     *  type       = specifies the type of operation occuring.
     *  context    = specifies a context relative to type.
     *  identifier = specifies what identifier we want the password
     *               for. This will be a value previously returned
     *               by $(D_PSYMBOL srpIdentifier).
     *
     * Returns: password for client-side SRP auth, if available
     *          for this identifier/type/context.
     */
    protected override string srpPassword(in string type,
        in string context, in string identifier)
    {
        return super.srpPassword(type, context, identifier);
    }

    /**
     * Retrieve SRP verifier parameters.
     */
    protected override bool srpVerifier(in string type, in string context,
        in string identifier, ref string group_name,ref BigInt verifier,
        ref Vector!ubyte salt, bool generate_fake_on_unknown)
    {
        return super.srpVerifier(type,
                                 context, 
                                 identifier,
                                 group_name,
                                 verifier,
                                 salt,
                                 generate_fake_on_unknown);
    }

    /**
     * Params:
     *  type    = specifies the type of operation occuring
     *  context = specifies a context relative to type.
     *
     * Returns: the PSK identity hint for this type/context.
     */
    protected override string pskIdentityHint(in string type, in string context)
    {
        return super.pskIdentityHint(type, context);
    }

    /**
     * Params:
     *  type          = specifies the type of operation occuring.
     *  context       = specifies a context relative to type.
     *  identity_hint = was passed by the server (but may be empty).
     *
     * Returns: the PSK identity we want to use.
     */
    protected override string pskIdentity(in string type,
        in string context, in string identity_hint)
    {
        return super.pskIdentity(type, context, identity_hint);
    }

    /**
     * Params:
     *  type     = specifies the type of operation occuring.
     *  context  = specifies a context relative to type.
     *  identity = is a PSK identity previously returned by $(D_PSYMBOL
     *             pskIdentity) for the same type and context.
     *
     * Returns: the PSK used for identity, or throw new an exception if no
     * key exists.
     */
    protected override SymmetricKey psk(in string type,
        in string context, in string identity)
    {
        return super.psk(type, context, identity);
    }
}
