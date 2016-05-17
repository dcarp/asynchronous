/**
 * TLS support.
 *
 * Copyright: © 2015-2016 Dragos Carp
 * License: Boost Software License - Version 1.0
 * Authors: Dragos Carp
 */
module asynchronous.tls;

version (Have_botan):

import botan.math.bigint.bigint;
import botan.algo_base.symkey;
import botan.tls.credentials_manager;
import botan.cert.x509.x509cert;

/**
 * Basic credentials manager.
 *
 * A type is a fairly static value that represents the general nature
 * of the transaction occuring. Currently used values are "tls-client"
 * and "tls-server". Context represents a hostname, email address,
 * username, or other identifier.
 */
class BasicTLSCredentialsManager : TLSCredentialsManager
{
    this(X509Certificate serverCert, X509Certificate CACert, PrivateKey key) 
    {
        auto cs = new CertificateStoreInMemory();

        this.serverCert = serverCert;
        this.CACert = CACert;
        this.key = key;

        cs.addCertificate(this.CACert);
        stores.pushBack(cs);
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
                }
            }
            
            if (haveMatch)
            {
                chain.pushBack(serverCert);
                chain.pushBack(CACert);
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
     *               by $(D_PSYMBOL srp_identifier).
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
     *  identity = is a PSK identity previously returned by
     *             psk_identity for the same type and context.
     *
     * Returns: the PSK used for identity, or throw new an exception if no
     * key exists.
     */
    override SymmetricKey psk(in string type, in string context, in string identity)
    {
        return super.psk(type, context, identity);
    }

    X509Certificate serverCert, CACert;
    Unique!PrivateKey key;
    Vector!CertificateStore stores;
}
