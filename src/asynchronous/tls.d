/**
 * TLS support.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.tls;

version (Have_botan):

import std.socket : SocketOSException;
import std.typecons : Tuple, tuple, Nullable;
import botan.math.bigint.bigint;
import botan.algo_base.symkey;
import botan.tls.credentials_manager : TLSCredentialsManager;
import botan.cert.x509.x509cert : X509Certificate;
import botan.rng.auto_rng : RandomNumberGenerator, AutoSeededRNG;
import botan.pubkey.pkcs8 : loadKey, PrivateKey;
import botan.tls.channel;
import botan.tls.server;
import botan.tls.client;
import asynchronous.transports;
import asynchronous.futures : Waiter;
import asynchronous.events : SslContext, EventLoop;
import asynchronous.types : NotImplementedException;

/** Supported TLS protocol versions */
enum ProtocolVersion
{
	TLSv1_2,
}

/**
 * Handshake failed.
 */
class HandshakeException : Exception
{
    this(string message = null, string file = __FILE__, size_t line = __LINE__,
        Throwable next = null) @safe pure nothrow
    {
		import std.format;
		if (message)
		{
			try {
				super(format("SSL handshake failed: %s", message), file, line, next);
				return;
			}
			catch (Exception)
			{
			}
		}
		super("SSL handshake failed.", file, line, next);
    }
}

/**
 * Creates a new TLS context.
 *
 * Params:
 *  ver = the protocol version.
 *
 * See_Also: $(D_PSYMBOL SslVersion)
 */
SslContext createSslContext(ProtocolVersion ver = ProtocolVersion.TLSv1_2)
{
	version (Have_botan)
	{
		return new BotanSslContext(ver);
	}
	assert(0);
}

abstract class SslProtocol : Protocol
{
	void startShutdown();

	void abort()
	{
	}

	void writeAppData(const(void)[] data)
	{
	}

private:
	Transport transport;
}

SslProtocol createSslProtocol(EventLoop eventLoop,
                              Protocol protocol,
						      SslContext sslContext)
{
	version (Have_botan)
	{
		return new BotanSslProtocol(eventLoop, protocol, sslContext);
	}
	assert(0);
}

/**
 * TLS protocol.
 *
 * Implementation of TLS.
 */
final class BotanSslProtocol : SslProtocol
{
    private EventLoop eventLoop;
    private Protocol appProtocol;
    private SslProtocolTransport appTransport;
    private BotanSslContext sslContext;
    private TLSChannel channel;
    private Waiter waiter;
	private bool inHandshake = true;

	this(EventLoop eventLoop,
	     Protocol appProtocol,
		 SslContext sslContext = null,
		 Waiter waiter = null,
	     bool serverSide = false,
		 string serverHostname = null)
	{
		auto mgr = new TLSSessionManagerNoop();
		auto policy = new TLSPolicy();

		this.eventLoop = eventLoop;
		this.appProtocol = appProtocol;
		this.appTransport = new SslProtocolTransport(eventLoop,
		                                             this,
													 this.appProtocol);
		this.waiter = waiter;

		this.sslContext = cast(BotanSslContext)sslContext;
		assert(sslContext !is null);

		this.channel = new TLSServer(&outputCb,
		                             &dataCb,
		                             delegate void(in TLSAlert, in ubyte[]) {},
							         &onHandshakeComplete,
							         mgr,
							         this.sslContext,
							         policy,
		                             this.sslContext.rng);

	}

	/**
	 * Called when the low-level connection is made.
	 * Start the SSL handshake.
	 */
	void connectionMade(BaseTransport transport)
	{
		this.transport = cast(Transport)transport;
	}

	void connectionLost(Exception exception)
	{
	}

	void pauseWriting()
	{
	}

	void resumeWriting()
	{
	}

	override void startShutdown()
	{
	}

	void dataReceived(const(void)[] data)
	{
		channel.receivedData(cast(ubyte*)data, data.length);
	}

	bool eofReceived()
	{
		return true;
	}

	private void wakeupWaiter(Exception exception)
	{
		if (waiter is null)
		{
			return;
		}
        if (!waiter.cancelled)
		{
			waiter.setException(exception);
		}
	}

	private void wakeupWaiter()
	{
		if (waiter is null)
		{
			return;
		}
        if (!waiter.cancelled)
		{
			waiter.setResult;
		}
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
				wakeupWaiter(new HandshakeException("Peer closed connection."));
				return;
			}
		}
		transport.write(data);
	}

    private void dataCb(in ubyte[] data)
	{
	}

    private bool onHandshakeComplete(in TLSSession session)
	{
		inHandshake = false;
		return true;
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
final class BotanSslContext : TLSCredentialsManager, SslContext
{
	/**
	 * Constructor.
	 *
	 * Params:
	 *  ver = the protocol version.
	 *
	 * See_Also: $(D_PSYMBOL SslVersion)
     */
	this(ProtocolVersion ver = ProtocolVersion.TLSv1_2)
	{
		protocolVersion = ver;
		rng = new AutoSeededRNG();
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
		certs.pushBack(X509Certificate(cast(DataSource)inp));
		// The following ones if available should be just intermediate and probably
		// root certificates. If it isn't the case it is the user's fault.
		while (!inp.endOfData())
		{
			try
			{
				auto cert = X509Certificate(cast(DataSource)inp);
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

protected:
    /**
     * Return a list of the certificates of CAs that we trust in this
     * type/context.
     *
     * Params:
     *  type    = specifies the type of operation occuring.
     *  context = specifies a context relative to type. For instance
     *            for type "tls-client", context specifies the servers name.
     */
    override Vector!CertificateStore trustedCertificateAuthorities(in string type,
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
    override void verifyCertificateChain(in string type,
                                         in string purported_hostname,
                                         const ref Vector!X509Certificate cert_chain)
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
    override Vector!X509Certificate certChain(const ref Vector!string cert_key_types,
                                              in string type,
                                              in string context)
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
    override Vector!X509Certificate certChainSingleType(in string cert_key_type,
                                                        in string type,
                                                        in string context)
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
    override PrivateKey privateKeyFor(in X509Certificate cert, in string type, in string context)
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
    override bool attemptSrp(in string type, in string context)
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
    override string srpIdentifier(in string type, in string context)
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
    override string srpPassword(in string type,
                                in string context,
                                in string identifier)
    {
        return super.srpPassword(type, context, identifier);
    }

    /**
     * Retrieve SRP verifier parameters.
     */
    override bool srpVerifier(in string type,
                              in string context,
                              in string identifier,
                              ref string group_name,
                              ref BigInt verifier,
                              ref Vector!ubyte salt,
                              bool generate_fake_on_unknown)
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
    override string pskIdentityHint(in string type, in string context)
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
    override string pskIdentity(in string type, in string context, in string identity_hint)
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
    override SymmetricKey psk(in string type, in string context, in string identity)
    {
        return super.psk(type, context, identity);
    }

private:
    Unique!PrivateKey key;
    Vector!X509Certificate certs;
    Vector!CertificateStore stores;
	ProtocolVersion protocolVersion;
	AutoSeededRNG rng;
}

package class SslProtocolTransport : FlowControlTransport
{
	this(EventLoop eventLoop, SslProtocol protocol, Protocol appProtocol)
	{
		super(eventLoop);

		this._protocol = protocol;
		this.appProtocol = appProtocol;
	}

	override @property SslProtocol protocol() pure nothrow @safe
	{
		return _protocol;
	}

	bool isClosing() pure nothrow @safe
	{
		return closed;
	}

	/**
	 * Close the transport.
	 *
     * Buffered data will be flushed asynchronously.  No more data
     * will be received. After all buffered data is flushed, the
     * protocol's connectionLost() method will be (eventually) called
     * with $(D_KEYWORD null) as its argument.
     */
	void close()
	{
		closed = true;
		protocol.startShutdown();
	}

	/**
	 * Pause the receiving end.
	 *
     * No data will be passed to the protocol's data_received()
     * method until resume_reading() is called.
     */
    void pauseReading()
	{
        protocol.transport.resumeReading();
	}

    /**
	 * Resume the receiving end.
	 *
     * Data received will once again be passed to the protocol's
     * $(D_PSYMBOL data_received()) method.
     */
    void resumeReading()
	{
        protocol.transport.resumeReading();
	}

    /**
     * Set the high- and low-water limits for write flow control.
     *
     * These two values control when to call the protocol's
     * $(D_PSYMBOL pauseWriting()) and $(D_PSYMBOL resumeWriting())
     *  methods. If specified, the low-water limit must be less than
     * or equal to the high-water limit.  Neither value can be negative.
     *
     * The defaults are implementation-specific. If only the
     * high-water limit is given, the low-water limit defaults to an
     * implementation-specific value less than or equal to the high-water
     * limit.  Setting high to zero forces low to zero as well, and causes
     * $(D_PSYMBOL pauseWriting()) to be called whenever the buffer becomes
     * non-empty. Setting low to zero causes $(D_PSYMBOL resumeWriting())
     * to be called only once the buffer is empty.
     * Use of zero for either limit is generally sub-optimal as it
     * reduces opportunities for doing I/O and computation concurrently.
     */
    override void setWriteBufferLimits(Nullable!size_t high = Nullable!size_t(),
                                       Nullable!size_t low = Nullable!size_t())
	{
		protocol.transport.setWriteBufferLimits(high, low);
	}

	/**
	 * Return the current size of the write buffer.
	 */
	size_t getWriteBufferSize()
	{
		return protocol.transport.getWriteBufferSize();
	}

	/**
	 * Write some data bytes to the transport.
	 *
     * This does not block; it buffers the data and arranges for it
     * to be sent out asynchronously.
     */
    void write(const(void)[] data)
	{
        if (data)
		{
			protocol.writeAppData(data);
		}
	}

	/**
	 * Return $(D_KEYWORD true) if this transport supports
	 * $(D_PSYMBOL writeEof()), $(D_KEYWORD false) if not.
	 */
    bool canWriteEof()
	{
		return false;
	}

	/**
	 * Close the transport immediately.
	 *
     * Buffered data will be lost. No more data will be received.
     * The protocol's $(D_PSYMBOL connectionLost()) method will
     * (eventually) be called with $(D_KEYWORD null) as its argument.
     */
    void abort()
	{
		protocol.abort();
	}

    /**
     * Close the write end of the transport after flushing buffered data.
     *
     * Data may still be received.
     *
     * Throws: $(D_PSYMBOL NotImplementedException).
     */
    void writeEof()
	{
		throw new NotImplementedException("SSL doesn't support half-closes");
	}

private:
	Protocol appProtocol;
	SslProtocol _protocol;
	bool closed;
}
