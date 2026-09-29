import com.cloudbees.plugins.credentials.CredentialsScope
import com.cloudbees.plugins.credentials.SystemCredentialsProvider
import com.cloudbees.plugins.credentials.domains.Domain
import com.cloudbees.plugins.credentials.impl.UsernamePasswordCredentialsImpl

import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey
import com.cloudbees.jenkins.plugins.sshcredentials.impl.BasicSSHUserPrivateKey.DirectEntryPrivateKeySource


def store = SystemCredentialsProvider.getInstance().getStore()
def domain = Domain.global()

def changed = false


// =====================================================
// GitOps Repository SSH Credential
// - neuroplan-hybrid/neuroplan-gitops clone/push
// =====================================================

def gitopsCredentialId = '$gitops_credential_id'
def gitopsPrivateKey   = '''$gitops_private_key'''
def gitopsDescription  = 'NeuroPlan Hybrid GitOps Repository Deploy Key'

def existingGitops = store.getCredentials(domain).find {
    it.id == gitopsCredentialId
}

def newGitopsCredential = new BasicSSHUserPrivateKey(
    CredentialsScope.GLOBAL,
    gitopsCredentialId,
    'git',
    new DirectEntryPrivateKeySource(gitopsPrivateKey),
    '',
    gitopsDescription
)

def existingGitopsPrivateKey = ''

if (existingGitops instanceof BasicSSHUserPrivateKey) {
    def keys = existingGitops.getPrivateKeys()

    if (keys != null && !keys.isEmpty()) {
        existingGitopsPrivateKey = keys[0].trim()
    }
}

def gitopsSame =
    existingGitops instanceof BasicSSHUserPrivateKey &&
    existingGitops.username == 'git' &&
    existingGitopsPrivateKey == gitopsPrivateKey.trim() &&
    existingGitops.description == gitopsDescription

if (!gitopsSame) {
    if (existingGitops != null) {
        store.updateCredentials(
            domain,
            existingGitops,
            newGitopsCredential
        )
    } else {
        store.addCredentials(
            domain,
            newGitopsCredential
        )
    }

    changed = true
}


// =====================================================
// AWS ECR Credential
// - Username = AWS Access Key ID
// - Password = AWS Secret Access Key
// =====================================================

def awsCredentialId = '$aws_credential_id'
def awsAccessKeyId   = '$aws_access_key_id'
def awsSecretKey     = '''$aws_secret_access_key'''
def awsDescription   = 'NeuroPlan Jenkins AWS ECR Credential'

def existingAws = store.getCredentials(domain).find {
    it.id == awsCredentialId
}

def newAwsCredential = new UsernamePasswordCredentialsImpl(
    CredentialsScope.GLOBAL,
    awsCredentialId,
    awsDescription,
    awsAccessKeyId,
    awsSecretKey
)

def awsSame =
    existingAws instanceof UsernamePasswordCredentialsImpl &&
    existingAws.username == awsAccessKeyId &&
    existingAws.password.plainText == awsSecretKey &&
    existingAws.description == awsDescription

if (!awsSame) {
    if (existingAws != null) {
        store.updateCredentials(
            domain,
            existingAws,
            newAwsCredential
        )
    } else {
        store.addCredentials(
            domain,
            newAwsCredential
        )
    }

    changed = true
}


store.save()

println(changed ? 'CHANGED' : 'UNCHANGED')
